"""OpenAPI must expose the typed submit contract (arch review Group C, #148).

The point of the typed payloads is that /verify-api and the iOS Codable diff
can see them in the schema. Before, GET /sessions/{id}/question had no
response_model and InputResponse.current_question was Dict[str, Any] — both
invisible; #148 extended the same guard to the rest of the submit response,
whose evaluation and audio halves were untyped dicts while iOS decoded them
into non-optional structs. These tests fail if any of the three regresses.
"""

from app.main import app

QUESTION_PATH = "/api/v1/sessions/{session_id}/question"
INPUT_PATH = "/api/v1/sessions/{session_id}/input"

# The 9 keys the legacy wire dict always carries (see
# test_public_question_contract.py); OpenAPI must list exactly these required.
ALWAYS_PRESENT_KEYS = {
    "id",
    "question",
    "type",
    "possible_answers",
    "difficulty",
    "topic",
    "category",
    "source_url",
    "source_excerpt",
}
OMITTABLE_KEYS = {
    "media_url",
    "image_subtype",
    "explanation",
    "age_appropriate",
    "generated_by",
}
# Answer-bearing fields that must not even exist as properties on the schema.
# `headline_answer` is the gist the evaluator scores against, so listing it as
# an omittable public key was blessing a pre-answer answer leak (#133 V8).
ANSWER_KEYS = {"correct_answer", "headline_answer"}

# The verdict payload (#148). Required = what iOS declares non-optional plus the
# id it grades; the two answer-detail keys are omitted from the wire when unset,
# exactly as PublicQuestion's optional keys are. Widening this set is a client
# contract change — the assertion is here so it cannot happen silently.
EVALUATION_REQUIRED_KEYS = {
    "user_answer",
    "result",
    "points",
    "correct_answer",
    "question_id",
}
EVALUATION_OMITTABLE_KEYS = {"headline_answer", "explanation"}

# The audio block (#148). Only `format` is always present; every carrier is
# conditional (inline base64 vs cache-backed URL, question audio only when there
# is a next question), which is why iOS declares them optional.
AUDIO_REQUIRED_KEYS = {"format"}
AUDIO_OMITTABLE_KEYS = {"feedback_url", "feedback_audio_base64", "question_url"}


def _resolve(schema, components):
    """Follow $ref chains to the concrete schema object."""
    while set(schema) == {"$ref"}:
        schema = components[schema["$ref"].rsplit("/", 1)[1]]
    return schema


def _response_schema(openapi, path, method):
    raw = openapi["paths"][path][method]["responses"]["200"]["content"][
        "application/json"
    ]["schema"]
    return _resolve(raw, openapi["components"]["schemas"])


def test_get_question_route_has_typed_response():
    openapi = app.openapi()
    wrapper = _response_schema(openapi, QUESTION_PATH, "get")
    # Wrapper carries the typed question, not a bare object.
    question_ref = wrapper["properties"]["question"]
    assert question_ref.get("$ref", "").endswith("PublicQuestion"), question_ref


def _optional_ref(schema_property):
    """The $ref inside an ``Optional[Model]`` property (FastAPI emits anyOf)."""
    return [v.get("$ref", "") for v in schema_property.get("anyOf", [schema_property])]


def test_input_response_question_is_typed():
    openapi = app.openapi()
    input_response = _response_schema(openapi, INPUT_PATH, "post")
    current_q = input_response["properties"]["current_question"]
    assert any(r.endswith("PublicQuestion") for r in _optional_ref(current_q)), (
        current_q
    )


def test_input_response_evaluation_is_typed():
    """The graded verdict is the money path's payload: the question was served,
    the freemium quota charged and a verdict produced. A free-form object here
    means neither /verify-api nor the iOS Codable diff can see the one response
    a charged answer comes back in (#148)."""
    openapi = app.openapi()
    input_response = _response_schema(openapi, INPUT_PATH, "post")
    evaluation = input_response["properties"]["evaluation"]
    refs = _optional_ref(evaluation)
    assert any(r.endswith("Evaluation") for r in refs), evaluation

    schema = _resolve(
        {"$ref": next(r for r in refs if r.endswith("Evaluation"))},
        openapi["components"]["schemas"],
    )
    assert set(schema["properties"]) == (
        EVALUATION_REQUIRED_KEYS | EVALUATION_OMITTABLE_KEYS
    )
    assert set(schema.get("required", [])) == EVALUATION_REQUIRED_KEYS


def test_input_response_audio_is_typed():
    """Same guard for the audio block: dropping `format` from one branch, or
    renaming a URL key, must break the schema here rather than at decode time on
    a shipped binary (#148)."""
    openapi = app.openapi()
    input_response = _response_schema(openapi, INPUT_PATH, "post")
    audio = input_response["properties"]["audio"]
    refs = _optional_ref(audio)
    assert any(r.endswith("AudioInfo") for r in refs), audio

    schema = _resolve(
        {"$ref": next(r for r in refs if r.endswith("AudioInfo"))},
        openapi["components"]["schemas"],
    )
    assert set(schema["properties"]) == AUDIO_REQUIRED_KEYS | AUDIO_OMITTABLE_KEYS
    assert set(schema.get("required", [])) == AUDIO_REQUIRED_KEYS


def test_public_question_schema_mirrors_wire_contract():
    openapi = app.openapi()
    components = openapi["components"]["schemas"]
    assert "PublicQuestion" in components, "PublicQuestion missing from schema"
    schema = _resolve(components["PublicQuestion"], components)
    props = set(schema["properties"])
    assert props == ALWAYS_PRESENT_KEYS | OMITTABLE_KEYS
    assert set(schema.get("required", [])) == ALWAYS_PRESENT_KEYS
    assert not (props & ANSWER_KEYS), props & ANSWER_KEYS
