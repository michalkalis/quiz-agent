"""Hand the week's `manual` posts to the founder through iCloud Drive (210.5).

Carousels get music, and only the Instagram app can add it (the API's audio
is for reels only), so the founder posts them from the phone (2026-11-04).
Each post becomes a folder in iCloud Drive/Trubbo Instagram/<week>/, e.g.
`sobota-7-11-EN`, with the slides in order (01.jpg, 02.jpg, ...) and
`popis.txt` (caption + when to post). Media come from the staged R2 URLs.

    python3 apps/social-studio/scripts/export_manual.py 2026-W45
"""

import json
import sys
import urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

APP_DIR = Path(__file__).resolve().parent.parent
ICLOUD = Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Trubbo Instagram"
DAYS = ["pondelok", "utorok", "streda", "stvrtok", "piatok", "sobota", "nedela"]
LABEL = {"ig_en": "EN", "ig_skcz": "SK-CZ"}


def main(week: str) -> None:
    manifest = json.loads((APP_DIR / "batches" / f"{week}.json").read_text())
    for post in manifest["posts"]:
        if post.get("status") != "manual":
            continue
        at = datetime.fromisoformat(post["publish_at"]).astimezone(
            ZoneInfo("Europe/Bratislava")
        )
        folder = (
            ICLOUD
            / week
            / f"{DAYS[at.weekday()]}-{at.day}-{at.month}-{LABEL[post['account']]}"
        )
        folder.mkdir(parents=True, exist_ok=True)
        for i, url in enumerate(post["media_urls"], 1):
            # r2.dev refuses Python's default User-Agent (403).
            req = urllib.request.Request(
                url, headers={"User-Agent": "trubbo-social-studio"}
            )
            with urllib.request.urlopen(req) as r:
                (folder / f"{i:02d}{Path(url).suffix}").write_bytes(r.read())
        when = at.strftime("%-d. %-m. o %H:%M")
        (folder / "popis.txt").write_text(
            f"Zverejniť {when} na @{'trubboapp' if post['account'] == 'ig_en' else 'trubboapp.sk'}, s hudbou.\n\n{post['caption']}\n"
        )
        print(f"✓ {folder.name}: {len(post['media_urls'])} slides")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: export_manual.py <week>")
    main(sys.argv[1])
