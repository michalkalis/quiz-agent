"""Stage a week's approved posts for the Instagram scheduler (210.5).

Runs locally after the founder approved the batch on the approval page:

    uv run --no-sync python apps/social-studio/scripts/stage_week.py 2026-W44 decisions.json

- decisions.json = the approval page's `decisions` rows (ArtifactData list),
  [{"key": "mon-ig_en", "status": "approved", ...}, ...].
- Each approved post's media is uploaded to the public `quiz-images` R2 bucket
  under `social/<week>/` (Instagram fetches media from a public URL), with the
  root `.env` R2_* credentials (run from the main checkout), the same as the image-question scripts.
  `--wrangler` uploads with the Cloudflare CLI's own login instead (`wrangler login`,
  CLOUDFLARE_ACCOUNT_ID set), for a machine whose `.env` R2 keys are stale.
- The manifest `batches/<week>.json` gets per post: `status`, `publish_at`
  (UTC slot) and `media_urls`. Commit it through a PR; the scheduler
  (scripts/publish_due.py, GitHub Actions) publishes only `approved` posts.
"""

import json
import os
import subprocess
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
# The company account's public bucket (the W44 posts' media_urls); `--wrangler` only.
WRANGLER_BUCKET = "quiz-images"
WRANGLER_PUBLIC_URL = "https://pub-93c1fbd068fe48a6848d4e647fe1596e.r2.dev"


def boto3_uploader():
    s3 = boto3.client(
        "s3",
        endpoint_url=os.environ["R2_ENDPOINT"],
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        config=Config(signature_version="s3v4"),
        region_name="auto",
    )
    bucket = os.environ["R2_BUCKET"]

    def put(path: Path, key: str) -> None:
        s3.upload_file(
            str(path), bucket, key, ExtraArgs={"ContentType": TYPES[path.suffix]}
        )

    return put, os.environ["R2_PUBLIC_URL"].rstrip("/")


def wrangler_put(path: Path, key: str) -> None:
    subprocess.run(
        [
            "wrangler",
            "r2",
            "object",
            "put",
            f"{WRANGLER_BUCKET}/{key}",
            "--file",
            str(path),
            "--content-type",
            TYPES[path.suffix],
            "--remote",
        ],
        check=True,
        capture_output=True,
    )


def publish_at(post: dict) -> str:
    at, tz = SLOTS[post["account"]]
    if post.get("time"):
        at = time.fromisoformat(post["time"])
    local = datetime.combine(date.fromisoformat(post["date"]), at, tz)
    return local.astimezone(UTC).isoformat().replace("+00:00", "Z")


def main(
    week: str, decisions_file: str, media_dir: Path, wrangler: bool = False
) -> None:
    load_dotenv(find_dotenv(usecwd=True))  # root .env of the checkout you run it from
    manifest_file = APP_DIR / "batches" / f"{week}.json"
    manifest = json.loads(manifest_file.read_text())
    status = {
        d["key"]: d.get("status") for d in json.loads(Path(decisions_file).read_text())
    }

    put, base = (wrangler_put, WRANGLER_PUBLIC_URL) if wrangler else boto3_uploader()

    for post in manifest["posts"]:
        if post.get("status") == "published":
            continue  # already on Instagram (a re-rendered week keeps them)
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
            put(media_dir / name, key)
            urls.append(f"{base}/{key}")
        post["media_urls"] = urls
        print(f"✓ {post['key']}: {len(urls)} files, publishes {post['publish_at']}")

    manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    use_wrangler = "--wrangler" in sys.argv
    args = [a for a in sys.argv[1:] if a != "--wrangler"]
    if len(args) < 2:
        sys.exit(
            "usage: stage_week.py <week> <decisions.json> [media dir, default out/<week>] [--wrangler]"
        )
    week = args[0]
    media = Path(args[2]) if len(args) > 2 else APP_DIR / "out" / week
    main(week, args[1], media, use_wrangler)
