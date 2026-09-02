"""Unit tests for the batch-inference adapter (issue #168, T2/DD7).

These encode the facts the live 5-request smoke established, so a later
refactor cannot quietly undo them:

- the route is OpenRouter's ``/api/beta/batches`` with **inline** requests —
  not the OpenAI Batch API's file-upload shape, which 404s here;
- a model without a batch endpoint is a routing fact the caller must see, not
  an error to swallow (standing rule: never substitute a model);
- an unavailable cost reads as ``None``, never ``0`` (DD9) — a fake zero would
  make "translate in batches as testers grow" look free;
- results are never read out of a job that did not complete.
"""

import httpx
import pytest
import respx
from quiz_shared.llm import batch

BATCH_URL = batch.OPENROUTER_BATCH_URL


@pytest.fixture(autouse=True)
def _key(monkeypatch):
    monkeypatch.setenv("OPENROUTER_API_KEY", "sk-or-test")
    # Batch is OpenRouter-only; the suite pins LLM_GATEWAY=direct (conftest),
    # which must NOT stop the adapter from resolving OpenRouter slugs.
    monkeypatch.setenv("LLM_GATEWAY", "direct")


def _reqs(n: int = 2) -> list[batch.BatchRequest]:
    return [
        batch.BatchRequest(
            custom_id=f"q{i}",
            body={"messages": [{"role": "user", "content": f"translate {i}"}]},
        )
        for i in range(n)
    ]


def _job_payload(**over):
    payload = {
        "id": "batch-1",
        "object": "batch",
        "endpoint": "/v1/chat/completions",
        "model": "anthropic/claude-opus-5-20260723",
        "status": "validating",
        "request_counts": {"total": 2, "completed": 0, "failed": 0},
        "usage": None,
        "results": None,
    }
    payload.update(over)
    return payload


@respx.mock
def test_submit_posts_inline_requests_to_the_beta_batches_route():
    """The smoke proved /api/v1/batches 404s and /api/beta/batches takes inline
    requests. Drifting back to the OpenAI file-upload shape breaks everything."""
    route = respx.post(BATCH_URL).mock(
        return_value=httpx.Response(202, json=_job_payload())
    )

    job = batch.submit("claude-opus-5", _reqs())

    assert route.called
    sent = route.calls.last.request
    body = httpx.Response(200, content=sent.content).json()
    assert body["endpoint"] == "/v1/chat/completions"
    # Direct id resolved to the OpenRouter slug even though LLM_GATEWAY=direct.
    assert body["model"] == "anthropic/claude-opus-5"
    assert [r["custom_id"] for r in body["requests"]] == ["q0", "q1"]
    assert job.id == "batch-1"
    assert job.status == "validating"
    assert not job.is_terminal


def test_slug_resolution_ignores_the_gateway_toggle(monkeypatch):
    """Batch exists only on OpenRouter, so LLM_GATEWAY must not gate the remap —
    the mirror image of factory's direct=True audio/image carve-out."""
    monkeypatch.setenv("LLM_GATEWAY", "direct")
    assert batch.to_openrouter_slug("claude-opus-5") == "anthropic/claude-opus-5"
    # An unknown id passes through so a caller can force any slug (e.g. a model
    # with no entry in the factory remap table).
    assert batch.to_openrouter_slug("google/gemini-2.5-pro") == "google/gemini-2.5-pro"


@respx.mock
def test_model_without_batch_endpoint_raises_its_own_error():
    """OpenRouter lists `openai/gpt-4.1:batch` in the catalog but the batch API
    rejects that model. The caller must be able to tell this apart and route it
    synchronously — swapping in a different model is forbidden."""
    respx.post(BATCH_URL).mock(
        return_value=httpx.Response(
            400,
            json={
                "error": {
                    "message": "Model 'openai/gpt-4.1' does not have a :batch endpoint.",
                    "code": 400,
                }
            },
        )
    )

    with pytest.raises(batch.BatchModelNotSupported):
        batch.submit("gpt-4.1", _reqs())


@respx.mock
def test_other_http_failures_are_generic_batch_errors():
    respx.post(BATCH_URL).mock(return_value=httpx.Response(500, text="boom"))
    with pytest.raises(batch.BatchError) as exc:
        batch.submit("claude-opus-5", _reqs())
    assert not isinstance(exc.value, batch.BatchModelNotSupported)


def test_duplicate_custom_ids_fail_loud():
    """Results are matched back by custom_id — a duplicate would silently drop
    one question's translation instead of failing."""
    dupes = [
        batch.BatchRequest(custom_id="same", body={"messages": []}),
        batch.BatchRequest(custom_id="same", body={"messages": []}),
    ]
    with pytest.raises(batch.BatchError, match="unique"):
        batch.submit("claude-opus-5", dupes)


def test_missing_api_key_fails_loud(monkeypatch):
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    with pytest.raises(batch.BatchError, match="OPENROUTER_API_KEY"):
        batch.submit("claude-opus-5", _reqs())


@respx.mock
def test_poll_reports_cost_none_when_usage_is_absent():
    """DD9: an unavailable spend read stores None, never a fake 0 — otherwise
    batch translation prices out as free."""
    respx.get(f"{BATCH_URL}/batch-1").mock(
        return_value=httpx.Response(200, json=_job_payload(status="in_progress"))
    )
    job = batch.poll("batch-1")
    assert job.cost_usd is None
    assert job.status == "in_progress"


@respx.mock
def test_poll_reports_provider_cost_and_terminal_state():
    respx.get(f"{BATCH_URL}/batch-1").mock(
        return_value=httpx.Response(
            200,
            json=_job_payload(
                status="completed",
                usage={"prompt_tokens": 175, "completion_tokens": 322, "cost": 0.0044625},
                request_counts={"total": 2, "completed": 2, "failed": 0},
            ),
        )
    )
    job = batch.poll("batch-1")
    assert job.cost_usd == pytest.approx(0.0044625)
    assert job.is_terminal
    assert job.failed_count == 0


def test_retrieve_refuses_a_job_that_did_not_complete():
    """A failed/expired job must never hand content to the ingest path."""
    job = batch._job_from_payload(_job_payload(status="failed"))
    with pytest.raises(batch.BatchError, match="not 'completed'"):
        batch.retrieve(job)


def test_retrieve_parses_content_and_marks_failed_items_not_ok():
    job = batch._job_from_payload(
        _job_payload(
            status="completed",
            results=[
                {
                    "custom_id": "q0",
                    "response": {
                        "status_code": 200,
                        "body": {
                            "choices": [
                                {"message": {"content": "Eiffelova veža je v Paríži."}}
                            ]
                        },
                    },
                    "error": None,
                },
                {
                    "custom_id": "q1",
                    "response": {"status_code": 500, "body": {}},
                    "error": {"message": "upstream refused"},
                },
            ],
        )
    )

    results = batch.retrieve(job)

    by_id = {r.custom_id: r for r in results}
    assert by_id["q0"].content == "Eiffelova veža je v Paríži."
    assert by_id["q0"].ok
    assert not by_id["q1"].ok
    assert by_id["q1"].content is None


def test_retrieve_fails_loud_on_a_completed_job_with_no_results_block():
    job = batch._job_from_payload(_job_payload(status="completed"))
    with pytest.raises(batch.BatchError, match="no results"):
        batch.retrieve(job)
