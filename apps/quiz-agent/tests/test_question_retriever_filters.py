"""Metadata-filter construction for QuestionRetriever.

Intent: MCQ questions must be retrievable by the voice quiz. MCQ is in the
first App Store launch batch (launch decision #3, 2026-06-08), so the
retriever's type filter has to admit ``text_multichoice`` — not just plain
``text``/``image``. If this filter ever drops ``text_multichoice`` again, MCQ
questions silently vanish from selection even though they're approved, so this
test guards the launch-critical contract rather than the literal list.
"""

from unittest.mock import MagicMock

from quiz_shared.models.session import QuizSession

from app.retrieval.question_retriever import QuestionRetriever


def _retriever() -> QuestionRetriever:
    # Pass a truthy store so __init__ skips _build_default_store() (which would
    # try to open a real pgvector connection).
    return QuestionRetriever(question_store=MagicMock())


def test_metadata_filter_admits_text_multichoice():
    retriever = _retriever()
    session = QuizSession(
        session_id="sess_test", current_difficulty="medium", language="en"
    )

    filters = retriever._build_metadata_filters("medium", session)

    allowed = filters["type"]["$in"]
    assert "text_multichoice" in allowed, (
        "MCQ questions must be selectable — text_multichoice dropped from the "
        "retriever type filter would silently exclude approved MCQ questions "
        "(launch decision #3)"
    )
    # The original plain-text path must keep working alongside MCQ.
    assert "text" in allowed


def test_metadata_filter_still_restricts_to_approved():
    # Guard against a regression where widening the type filter accidentally
    # relaxes the human-review gate.
    retriever = _retriever()
    session = QuizSession(
        session_id="sess_test", current_difficulty="medium", language="en"
    )

    filters = retriever._build_metadata_filters("medium", session)

    assert filters["review_status"] == "approved"


def test_metadata_filter_excludes_image_by_default():
    # #68: image questions are unsuitable while driving — a session that did
    # not opt in must never be served an image question, or a driver gets a
    # blank/visual-only prompt at the wheel.
    retriever = _retriever()
    session = QuizSession(
        session_id="sess_test", current_difficulty="medium", language="en"
    )

    filters = retriever._build_metadata_filters("medium", session)

    assert "image" not in filters["type"]["$in"]


def test_metadata_filter_admits_image_when_opted_in():
    # #68: the Home-screen "Image questions" toggle must actually reach
    # selection — opting in and still never seeing an image question would
    # make the setting a silent no-op.
    retriever = _retriever()
    session = QuizSession(
        session_id="sess_test",
        current_difficulty="medium",
        language="en",
        include_images=True,
    )

    filters = retriever._build_metadata_filters("medium", session)

    assert "image" in filters["type"]["$in"]


def test_fallback_retrieval_respects_image_opt_out():
    # #68: the fallback paths query the store directly with their own type
    # lists — if they re-admit "image" for an opted-out session, the default-
    # off guarantee only holds until the primary search comes back empty.
    retriever = _retriever()
    store = retriever._store
    store.search.return_value = []
    session = QuizSession(
        session_id="sess_test", current_difficulty="medium", language="en"
    )

    retriever._fallback_retrieval(session, "medium", n_candidates=5, excluded_ids=[])

    assert store.search.call_count > 0
    for call in store.search.call_args_list:
        allowed = call.kwargs["filters"]["type"]["$in"]
        assert "image" not in allowed


def test_pack_session_scopes_to_pack_id_only():
    # #95: playing a custom pack must serve EXACTLY that pack's questions — the
    # pack is the curation boundary, so pack_id scoping replaces the global
    # constraints. Crucially it must drop review_status: delivered pack questions
    # stay `pending_review` (they are never promoted into the shared corpus), so
    # if the "approved" gate survived here every pack would play as an EMPTY quiz.
    retriever = _retriever()
    session = QuizSession(
        session_id="sess_pack",
        current_difficulty="hard",
        language="sk",  # non-en would normally add a language_dependent filter
        pack_id="e5b8c1a2-0000-4000-8000-000000000abc",
        preferred_categories=["music"],  # would normally add a category filter
    )

    filters = retriever._build_metadata_filters("hard", session)

    assert filters["pack_id"] == "e5b8c1a2-0000-4000-8000-000000000abc"
    assert "review_status" not in filters  # pending_review pack Qs must be servable
    assert (
        "difficulty" not in filters
    )  # a pack is a fixed bundle, not difficulty-scoped
    assert "category" not in filters  # pack scoping overrides the category picker
    assert "language_dependent" not in filters
    # The image-safety opt-out is the one constraint that still applies.
    assert "image" not in filters["type"]["$in"]


def test_normal_session_never_serves_pack_questions():
    # #95: a custom pack is private, user-scoped paid content. The shared free
    # quiz must never surface it — `pack_id IS NULL` keeps normal sessions on the
    # curated global corpus. Without this guard, one approve-click on a pack
    # question would leak someone's private pack into strangers' quizzes.
    retriever = _retriever()
    session = QuizSession(
        session_id="sess_normal", current_difficulty="medium", language="en"
    )

    filters = retriever._build_metadata_filters("medium", session)

    assert "pack_id" in filters
    assert filters["pack_id"] is None


def test_pack_session_fallback_never_hits_global_library():
    # #95: a pack is a closed set. If the primary search comes back empty (pack
    # exhausted), the fallback must NOT reach into the shared corpus — that would
    # leak global questions into a paid pack AND bypass quota on them. It returns
    # empty so the quiz ends cleanly instead of silently continuing off-pack.
    retriever = _retriever()
    store = retriever._store
    session = QuizSession(
        session_id="sess_pack",
        current_difficulty="medium",
        language="en",
        pack_id="e5b8c1a2-0000-4000-8000-000000000abc",
    )

    result = retriever._fallback_retrieval(
        session, "medium", n_candidates=5, excluded_ids=[]
    )

    assert result == []
    store.search.assert_not_called()
