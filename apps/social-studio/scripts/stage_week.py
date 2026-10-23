"""Stage a week's approved posts for the Instagram scheduler (210.5).

Runs locally after the founder approved the batch on the approval page:

    uv run --no-sync python apps/social-studio/scripts/stage_week.py 2026-W44 decisions.json

- decisions.json = the approval page's `decisions` rows (ArtifactData list),
  [{"key": "mon-ig_en", "status": "approved", ...}, ...].
- Each approved post's media is uploaded to the public `quiz-images` R2 bucket
  under `social/<week>/` (Instagram fetches media from a public URL), with the
  root `.env` R2_* credentials (run from the main checkout), the same as the image-question scripts.
- The manifest `batches/<week>.json` gets per post: `status`, `publish_at`
  (UTC slot) and `media_urls`. Commit it through a PR; the scheduler
  (scripts/publish_due.py, GitHub Actions) publishes only `approved` posts.
"""

import json
import os
import sys
from datetime import UTC, date, datetime, time
from pathlib import Path
from zoneinfo import ZoneInfo

import boto3
from botocore.config import Config
from dotenv import find_dotenv, load_dotenv

APP_DIR = Path(__file__).resolve().parent.parent

# Default local posting time per account (a post's own `time` wins, e.g. the
# 10:00 / 14:00 launch posts). EN: 18:00 London = early afternoon US East.
SLOTS = {
    "ig_en": (time(18, 0), ZoneInfo("Europe/London")),
    "ig_skcz": (time(18, 0), ZoneInfo("Europe/Bratislava")),
}
TYPES = {".mp4": "video/mp4", ".jpg": "image/jpeg"}


def publish_at(post: dict) -> str:
    at, tz = SLOTS[post["account"]]
    if post.get("time"):
        at = time.fromisoformat(post["time"])
    local = datetime.combine(date.fromisoformat(post["date"]), at, tz)
    return local.astimezone(UTC).isoformat().replace("+00:00", "Z")


def main(week: str, decisions_file: str, media_dir: Path) -> None:
    load_dotenv(find_dotenv(usecwd=True))  # root .env of the checkout you run it from
    manifest_file = APP_DIR / "batches" / f"{week}.json"
    manifest = json.loads(manifest_file.read_text())
    status = {
        d["key"]: d.get("status") for d in json.loads(Path(decisions_file).read_text())
    }

    s3 = boto3.client(
        "s3",
        endpoint_url=os.environ["R2_ENDPOINT"],
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        config=Config(signature_version="s3v4"),
        region_name="auto",
    )
    bucket = os.environ["R2_BUCKET"]
    base = os.environ["R2_PUBLIC_URL"].rstrip("/")

    for post in manifest["posts"]:
        post["status"] = status.get(post["key"]) or "pending"
        # A staged post keeps its slot (it may have been moved by hand).
        if not post.get("media_urls"):
            post["publish_at"] = publish_at(post)
        if post["status"] != "approved":
            post.pop("media_urls", None)
            print(f"  {post['key']}: {post['status']}, not staged")
            continue
        urls = []
        for name in post["files"]:
            key = f"social/{week}/{name}"
            s3.upload_file(
                str(media_dir / name),
                bucket,
                key,
                ExtraArgs={"ContentType": TYPES[Path(name).suffix]},
            )
            urls.append(f"{base}/{key}")
        post["media_urls"] = urls
        print(f"✓ {post['key']}: {len(urls)} files, publishes {post['publish_at']}")

    manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(
            "usage: stage_week.py <week> <decisions.json> [media dir, default out/<week>]"
        )
    week = sys.argv[1]
    media = Path(sys.argv[3]) if len(sys.argv) > 3 else APP_DIR / "out" / week
    main(week, sys.argv[2], media)
