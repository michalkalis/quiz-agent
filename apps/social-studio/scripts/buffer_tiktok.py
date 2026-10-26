"""TikTok through Buffer: schedule a week's approved reels (210, decision 14).

TikTok's own Content Posting API keeps posts private until its audit passes,
and TikTok blocks browser automation, so until the audit Buffer (official
TikTok partner, free plan: 3 channels, 10 scheduled posts per channel at a
time) publishes them. Buffer keeps the schedule, so this runs once per week,
after stage_week.py has uploaded the media:

    uv run --no-sync python apps/social-studio/scripts/buffer_tiktok.py 2026-W44
    uv run --no-sync python apps/social-studio/scripts/buffer_tiktok.py --check

- Key: root .env BUFFER_API_KEY (publish.buffer.com/settings/api). Never printed.
- Each approved, staged reel whose slot is still ahead goes to the TikTok
  channel of its account; carousels are skipped (Buffer has no TikTok
  carousels). Buffer's post id is written to the manifest as `tiktok_buffer`,
  so a re-run never schedules a post twice. Commit the manifest through a PR.
"""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

from dotenv import find_dotenv, load_dotenv

API = "https://api.buffer.com"
BATCH_DIR = Path(__file__).resolve().parent.parent / "batches"
# TikTok handle connected in Buffer, per Instagram account of the manifest.
CHANNELS = {"ig_en": "trubboapp"}


def gql(query: str, variables: dict | None = None) -> dict:
    req = urllib.request.Request(
        API,
        data=json.dumps({"query": query, "variables": variables or {}}).encode(),
        headers={
            "Authorization": f"Bearer {os.environ['BUFFER_API_KEY']}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            body = json.load(resp)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Buffer: {e.code} {e.read().decode()[:500]}") from None
    if body.get("errors"):
        raise RuntimeError(f"Buffer: {json.dumps(body['errors'])[:500]}")
    return body["data"]


def tiktok_channels() -> dict[str, str]:
    """Buffer channel id per account, matched on the TikTok handle."""
    orgs = gql("{ account { organizations { id } } }")["account"]["organizations"]
    found = {}
    for org in orgs:
        channels = gql(
            "query($org: OrganizationId!) { channels(input: {organizationId: $org})"
            " { id name service } }",
            {"org": org["id"]},
        )["channels"]
        for ch in channels:
            if ch["service"].lower() != "tiktok":
                continue
            for account, handle in CHANNELS.items():
                if ch["name"].lstrip("@") == handle:
                    found[account] = ch["id"]
    return found


CREATE = """mutation($input: CreatePostInput!) { createPost(input: $input) {
  ... on PostActionSuccess { post { id dueAt } }
  ... on MutationError { message } } }"""


def schedule(week: str) -> None:
    manifest_file = BATCH_DIR / f"{week}.json"
    manifest = json.loads(manifest_file.read_text())
    channels = tiktok_channels()
    now = datetime.now(UTC)
    for post in manifest["posts"]:
        if post.get("status") != "approved" or post["format"] == "carousel":
            continue
        if post.get("tiktok_buffer") or not post.get("media_urls"):
            continue
        if datetime.fromisoformat(post["publish_at"]) <= now:
            print(f"  {post['key']}: slot passed, not scheduled")
            continue
        if post["account"] not in channels:
            print(f"  {post['key']}: no TikTok channel in Buffer for {post['account']}")
            continue
        video = next(u for u in post["media_urls"] if u.endswith(".mp4"))
        result = gql(
            CREATE,
            {
                "input": {
                    "text": post["caption"],
                    "channelId": channels[post["account"]],
                    "schedulingType": "automatic",
                    "mode": "customScheduled",
                    "dueAt": post["publish_at"],
                    "needsApproval": False,
                    "assets": [{"video": {"url": video}}],
                    # Synthetic voice: disclose it, as on the Instagram reels.
                    "metadata": {"tiktok": {"isAiGenerated": True}},
                }
            },
        )["createPost"]
        if "message" in result:
            print(f"✗ {post['key']}: {result['message']}")
            continue
        post["tiktok_buffer"] = result["post"]["id"]
        print(f"✓ {post['key']}: TikTok at {result['post']['dueAt']}")
    manifest_file.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    load_dotenv(find_dotenv(usecwd=True))
    if len(sys.argv) < 2:
        sys.exit("usage: buffer_tiktok.py <week> | --check")
    if sys.argv[1] == "--check":
        print(json.dumps(tiktok_channels()))
    else:
        schedule(sys.argv[1])
