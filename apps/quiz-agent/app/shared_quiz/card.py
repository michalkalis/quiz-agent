"""The score card a shared daily challenge shows in a chat's link preview
(#249.6) and the words around it.

Chat apps (iMessage, WhatsApp, Messenger) build a link preview from the
page's Open Graph tags. The card is the ``og:image``: the sender's score and
mark row, the day and a hook. It never carries a question or an answer, only
what the sender's own message already says. The iOS app draws the same card
for the share sheet (``DailyShareCardView``); keep the two alike.
"""

from __future__ import annotations

import io
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Optional, Tuple

from PIL import Image, ImageChops, ImageDraw, ImageFont

WIDTH, HEIGHT = 1200, 630
_ASSETS = Path(__file__).parent / "assets"

# The app's palette (Theme.swift Palette).
COBALT, VIOLET = (44, 69, 245), (122, 92, 255)
MINT, MANDARIN, YELLOW, INK, WHITE = (
    (63, 224, 174),
    (255, 107, 44),
    (255, 210, 63),
    (17, 18, 22),
    (255, 255, 255),
)

# Words per quiz language: sk | cs | en | uk. "dnes" in the title is the
# founder's wording (2026-11-26): a daily link is opened the day it is sent.
_WORDS = {
    "sk": {
        "challenge": "denná výzva",
        "hook": "Dáš viac?",
        "title": "{name} má dnes {score} z {total}",
        "title_anon": "Denná výzva: {score} z {total}",
        "description": "Tie isté otázky. Dáš viac?",
    },
    "cs": {
        "challenge": "denní výzva",
        "hook": "Dáš víc?",
        "title": "{name} má dnes {score} z {total}",
        "title_anon": "Denní výzva: {score} z {total}",
        "description": "Stejné otázky. Dáš víc?",
    },
    "en": {
        "challenge": "daily challenge",
        "hook": "Can you beat it?",
        "title": "{name} got {score} of {total} today",
        "title_anon": "Daily challenge: {score} of {total}",
        "description": "Same questions. Can you beat it?",
    },
    "uk": {
        "challenge": "щоденний виклик",
        "hook": "Зможеш більше?",
        "title": "{name}: сьогодні {score} з {total}",
        "title_anon": "Щоденний виклик: {score} з {total}",
        "description": "Ті самі питання. Зможеш більше?",
    },
}
_UK_MONTHS = [
    "січня", "лютого", "березня", "квітня", "травня", "червня",
    "липня", "серпня", "вересня", "жовтня", "листопада", "грудня",
]  # fmt: skip
_EN_MONTHS = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
]  # fmt: skip
MAX_NAME = 24
MAX_TILES = 10


def words(language: str) -> dict:
    return _WORDS.get(language, _WORDS["en"])


@dataclass(frozen=True)
class CardData:
    """Everything a card shows. ``score`` is None for the generic card (a link
    that is unknown, or not a daily)."""

    language: str = "en"
    score: Optional[float] = None
    total: int = 0
    marks: Tuple[Optional[bool], ...] = ()
    month: Optional[int] = None
    day: Optional[int] = None
    name: Optional[str] = None


def score_text(score: float) -> str:
    """ "4", or "4.5" for a part-right answer (as the app shows it)."""
    return str(int(score)) if score == int(score) else f"{score:.1f}"


def day_label(language: str, month: Optional[int], day: Optional[int]) -> str:
    """ "26. 11." in Slovak and Czech, "26 листопада" style in Ukrainian,
    "Nov 26" otherwise (the app's ``DailyChallengeDay.label``)."""
    if not month or not day or not 1 <= month <= 12:
        return ""
    if language in ("sk", "cs"):
        return f"{day}. {month}."
    if language == "uk":
        return f"{day} {_UK_MONTHS[month - 1]}"
    return f"{_EN_MONTHS[month - 1]} {day}"


def clean_name(name: Optional[str]) -> Optional[str]:
    name = " ".join((name or "").split())[:MAX_NAME].strip()
    return name or None


def og_title(data: CardData) -> str:
    w = words(data.language)
    if data.score is None:
        return {
            "sk": "Denná výzva v Trubbe",
            "cs": "Denní výzva v Trubbu",
            "uk": "Щоденний виклик у Trubbo",
        }.get(data.language, "Daily challenge in Trubbo")
    fields = {"score": score_text(data.score), "total": data.total}
    name = clean_name(data.name)
    return (w["title"] if name else w["title_anon"]).format(name=name, **fields)


def og_description(data: CardData) -> str:
    return words(data.language)["description"]


def _font(weight: str, size: int, language: str = "en") -> ImageFont.FreeTypeFont:
    # Rethink Sans (the app's face) has no Cyrillic; Manrope, also bundled in
    # the app, does.
    family = "Manrope" if language == "uk" else "RethinkSans"
    return ImageFont.truetype(str(_ASSETS / f"{family}-{weight}.ttf"), size)


def _background() -> Image.Image:
    mask = Image.linear_gradient("L").rotate(90).resize((WIDTH, HEIGHT))
    img = Image.composite(
        Image.new("RGB", (WIDTH, HEIGHT), COBALT),
        Image.new("RGB", (WIDTH, HEIGHT), VIOLET),
        mask,
    )
    # Tilted cards on the right, as on the app's other share images.
    for x, y, color, angle in [(800, 300, MINT, -8), (930, 120, MANDARIN, 12)]:
        layer = Image.new("RGBA", (330, 440), color + (255,))
        round_mask = Image.new("L", layer.size, 0)
        ImageDraw.Draw(round_mask).rounded_rectangle(
            (0, 0, 329, 439), radius=30, fill=255
        )
        layer.putalpha(ImageChops.multiply(layer.getchannel("A"), round_mask))
        layer = layer.rotate(angle, expand=True, resample=Image.BICUBIC)
        img.paste(layer, (x, y), layer)
    return img


def _tile(draw: ImageDraw.ImageDraw, x: int, y: int, size: int, mark) -> None:
    box = (x, y, x + size, y + size)
    radius = size // 4
    if mark is None:
        draw.rounded_rectangle(box, radius, outline=WHITE, width=4)
        return
    draw.rounded_rectangle(box, radius, fill=MINT if mark else MANDARIN)
    w, u = max(size // 9, 6), size / 100
    if mark:
        points = [
            (x + 28 * u, y + 52 * u),
            (x + 44 * u, y + 67 * u),
            (x + 73 * u, y + 34 * u),
        ]
        draw.line(points, fill=INK, width=w, joint="curve")
    else:
        draw.line((x + 32 * u, y + 32 * u, x + 68 * u, y + 68 * u), fill=INK, width=w)
        draw.line((x + 68 * u, y + 32 * u, x + 32 * u, y + 68 * u), fill=INK, width=w)


def _text(draw, xy, text, weight, size, fill, spacing=0, language="en"):
    font = _font(weight, size, language)
    if not spacing:
        draw.text(xy, text, font=font, fill=fill)
        return
    x, y = xy
    for ch in text:
        draw.text((x, y), ch, font=font, fill=fill)
        x += font.getlength(ch) + spacing


def render(data: CardData) -> bytes:
    """The 1200x630 PNG for ``data``."""
    img = _background()
    draw = ImageDraw.Draw(img)
    w = words(data.language)
    head = "TRUBBO"
    label = w["challenge"].upper()
    when = day_label(data.language, data.month, data.day)
    lang = data.language
    _text(draw, (80, 64), head, "ExtraBold", 40, WHITE, 4, lang)
    _text(draw, (80, 120), f"{label} {when}".strip(), "Bold", 34, WHITE, 2, lang)
    if data.score is None:
        _text(draw, (80, 250), w["hook"], "ExtraBold", 120, YELLOW, 0, lang)
    else:
        _text(
            draw,
            (80, 140),
            f"{score_text(data.score)}/{data.total}",
            "ExtraBold",
            250,
            WHITE,
            0,
            lang,
        )
        marks = list(data.marks[:MAX_TILES])
        if marks:
            size = min(92, (700 - 16 * (len(marks) - 1)) // len(marks))
            for i, mark in enumerate(marks):
                _tile(draw, 80 + i * (size + 16), 398, size, mark)
        _text(draw, (80, 508), w["hook"], "ExtraBold", 56, YELLOW, 0, lang)
    out = io.BytesIO()
    img.save(out, "PNG", optimize=True)
    return out.getvalue()


@lru_cache(maxsize=256)
def render_cached(data: CardData) -> bytes:
    """A share's data never changes, so its image is drawn once per process."""
    return render(data)
