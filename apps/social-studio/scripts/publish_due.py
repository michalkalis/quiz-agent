"""Publish due Instagram posts (210.5) and their reels to Facebook Pages (210.11). Run hourly by .github/workflows/social-publish.yml.

The Instagram API has no scheduling, so this is the scheduler: every approved,
staged post in batches/*.json (scripts/stage_week.py) whose `publish_at` has
passed in the last 24 h is published through the Instagram API with Instagram
Login (graph.instagram.com). Stdlib only, so the workflow needs no install.

- Tokens: env IG_TOKEN_IG_EN / IG_TOKEN_IG_SKCZ (GitHub secrets, long-lived,
  refreshed weekly by scripts/ig_tokens.py). A due post without a token fails.
- Idempotent without state: a post whose caption is already on the account's
  latest media counts as published, so a rerun never posts twice.
- Reels also go to the matching Facebook Page (scripts/fb_pages.py), with
  the same window and idempotency rules.
- A post past its 24 h window, or one that fails, fails the run (the workflow
  goes red) instead of silently dropping.

    python apps/social-studio/scripts/publish_due.py            # publish what is due
    python apps/social-studio/scripts/publish_due.py --dry-run  # only list it
    python apps/social-studio/scripts/publish_due.py --check    # tokens, usernames, quota
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime, timedelta
from pathlib import Path

import fb_pages

API = "https://graph.instagram.com/v26.0"
BATCH_DIR = Path(__file__).resolve().parent.parent / "batches"
WINDOW = timedelta(
    hours=24
)  # containers expire after 24 h; later = missed, never posted late
ACCOUNTS = ("ig_en", "ig_skcz")


def call(method: str, path: str, token: str, **params) -> dict:
    data = urllib.parse.urlencode({**params, "access_token": token})
    url = f"{API}/{path}"
    req = (
        urllib.request.Request(f"{url}?{data}")
        if method == "GET"
        else urllib.request.Request(url, data=data.encode(), method="POST")
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as e:
        raise RuntimeError(
            f"{method} {path}: {e.code} {e.read().decode()[:500]}"
        ) from None


def token_for(account: str) -> str | None:
    return os.environ.get(f"IG_TOKEN_{account.upper()}") or None


def wait_ready(container: str, token: str) -> None:
    for _ in range(30):  # docs: poll up to 5 min; video processing can take a while
        status = call("GET", container, token, fields="status_code")["status_code"]
        if status == "FINISHED":
            return
        if status in ("ERROR", "EXPIRED"):
            detail = call("GET", container, token, fields="status")
            raise RuntimeError(
                f"container {container}: {status} {detail.get('status', '')}"
            )
        time.sleep(10)
    raise RuntimeError(f"container {container}: not ready after 5 min")


def publish(post: dict, user_id: str, token: str) -> str:
    urls = post["media_urls"]
    if post["format"] == "carousel":
        children = [
            call(
                "POST", f"{user_id}/media", token, image_url=u, is_carousel_item="true"
            )["id"]
            for u in urls
        ]
        for child in children:
            wait_ready(child, token)
        params = {"media_type": "CAROUSEL", "children": ",".join(children)}
    else:
        video = next(u for u in urls if u.endswith(".mp4"))
        cover = next((u for u in urls if u.endswith(".jpg")), None)
        params = {"media_type": "REELS", "video_url": video, "share_to_feed": "true"}
        if cover:
            params["cover_url"] = cover
        # Reels carry the app's synthetic voice: label them (Meta AI disclosure).
        params["is_ai_generated"] = "true"
    container = call(
        "POST", f"{user_id}/media", token, caption=post["caption"], **params
    )["id"]
    wait_ready(container, token)
    media = call("POST", f"{user_id}/media_publish", token, creation_id=container)["id"]
    return call("GET", media, token, fields="permalink").get("permalink", media)


def due_posts(now: datetime) -> list[tuple[dict, bool]]:
    """(post, missed) for approved, staged posts whose slot has passed."""
    out = []
    for file in sorted(BATCH_DIR.glob("*-W*.json")):
        for post in json.loads(file.read_text())["posts"]:
            if post.get("status") != "approved" or not post.get("media_urls"):
                continue
            at = datetime.fromisoformat(post["publish_at"])
            if (
                at <= now < at + 2 * WINDOW
            ):  # a miss stays red for one more day, then drops
                out.append((post, now - at > WINDOW))
    return out


def check() -> None:
    for account in ACCOUNTS:
        token = token_for(account)
        if not token:
            print(f"{account}: no token")
            continue
        me = call("GET", "me", token, fields="user_id,username,account_type")
        quota = call(
            "GET",
            f"{me['user_id']}/content_publishing_limit",
            token,
            fields="quota_usage,config",
        )
        print(
            f"{account}: @{me['username']} ({me.get('account_type')}), quota {json.dumps(quota.get('data', quota))}"
        )


def recent_captions(token: str) -> tuple[str, set[str]]:
    me = call("GET", "me", token, fields="user_id")
    recent = call("GET", "me/media", token, fields="caption", limit=25)
    return me["user_id"], {m.get("caption", "").strip() for m in recent.get("data", [])}


def publish_to(target: str, post: dict, missed: bool, dry_run: bool, seen: dict) -> int:
    """Publish one due post to Instagram ("ig") or its Facebook Page ("fb"); 1 = failure."""
    label = f"{post['key']}{' → Facebook' if target == 'fb' else ''}"
    token = (fb_pages.token_for if target == "fb" else token_for)(post["account"])
    if not token:
        print(f"✗ {label}: no {target} token for {post['account']}, not posted")
        return 1
    if post["account"] not in seen:
        try:  # one broken account must not stop the others
            seen[post["account"]] = (
                fb_pages.recent_descriptions if target == "fb" else recent_captions
            )(token)
        except RuntimeError as e:
            print(f"✗ {label}: {e}")
            return 1
    owner, captions = seen[post["account"]]
    if post["caption"].strip() in captions:
        return 0  # already on the account
    if missed:
        print(f"✗ {label} ({post['publish_at']}): missed its 24 h window, not posted")
        return 1
    if dry_run:
        print(f"would publish {label} ({post['format']}, {post['publish_at']})")
        return 0
    try:
        link = (fb_pages.publish_reel if target == "fb" else publish)(
            post, owner, token
        )
        print(f"✓ {label}: {link}")
        captions.add(post["caption"].strip())
        return 0
    except RuntimeError as e:
        print(f"✗ {label}: {e}")
        return 1


def main(dry_run: bool) -> int:
    failures = 0
    ig_seen: dict[str, tuple[str, set[str]]] = {}
    fb_seen: dict[str, tuple[str, set[str]]] = {}
    for post, missed in due_posts(datetime.now(UTC)):
        failures += publish_to("ig", post, missed, dry_run, ig_seen)
        if post["format"] != "carousel":  # Pages get the reels only (decision 10)
            failures += publish_to("fb", post, missed, dry_run, fb_seen)
    return 1 if failures else 0


if __name__ == "__main__":
    if "--check" in sys.argv:
        check()
        fb_pages.check()
    else:
        sys.exit(main("--dry-run" in sys.argv))
