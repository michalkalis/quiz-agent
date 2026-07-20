"""OpenAPI must expose the typed question contract (arch review Group C).

The point of PublicQuestion is that /verify-api and the iOS Codable diff can
see the question payload in the schema. Before, GET /sessions/{id}/question
had no response_model and InputResponse.current_question was Dict[str, Any] —
both invisible. These tests fail if either regresses to an untyped dict.
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
    "headline_answer",
    "generated_by",
}


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


def test_input_response_question_is_typed():
    openapi = app.openapi()
    input_response = _response_schema(openapi, INPUT_PATH, "post")
    current_q = input_response["properties"]["current_question"]
    refs = [v.get("$ref", "") for v in current_q.get("anyOf", [current_q])]
    assert any(r.endswith("PublicQuestion") for r in refs), current_q


def test_public_question_schema_mirrors_wire_contract():
    openapi = app.openapi()
    components = openapi["components"]["schemas"]
    assert "PublicQuestion" in components, "PublicQuestion missing from schema"
    schema = _resolve(components["PublicQuestion"], components)
    props = set(schema["properties"])
    assert props == ALWAYS_PRESENT_KEYS | OMITTABLE_KEYS
    assert set(schema.get("required", [])) == ALWAYS_PRESENT_KEYS
    assert "correct_answer" not in props
