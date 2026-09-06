"""``GET /api/v1/languages`` — which languages the app may currently offer.

#168 — batch translation pipeline SK/CS (DD14/DD15). The iOS picker used to
hard-code all ten languages, so hiding one (or bringing one back as its
translated corpus is approved) meant a code change and a TestFlight build. This
endpoint makes the menu data: the client fetches it at launch and filters its
display catalogue, and re-enabling a language becomes an env flip
(``SERVABLE_QUIZ_LANGUAGES`` / ``PACK_ORDER_LANGUAGES``) on a running deploy.

Two lists, because they differ: quiz sessions can serve any language with an
approved corpus, while custom packs are generated in English and only *stamped*
with the ordered code (DD15), so pack ordering stays English-only until pack
generation is natively multi-language.

Unauthenticated on purpose — it is public product configuration, needed before
a client has any identity, and it exposes nothing a user cannot read off the
picker.
"""

from __future__ import annotations

from fastapi import APIRouter
from pydantic import BaseModel

from quiz_shared.languages import pack_order_languages, servable_quiz_languages

router = APIRouter(prefix="/v1/languages", tags=["languages"])


class LanguagesResponse(BaseModel):
    quiz: list[str]
    pack_order: list[str]


@router.get("", response_model=LanguagesResponse)
async def get_languages() -> LanguagesResponse:
    """The servable quiz languages and the orderable pack languages."""
    return LanguagesResponse(
        quiz=list(servable_quiz_languages()),
        pack_order=list(pack_order_languages()),
    )
