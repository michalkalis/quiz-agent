"""Facebook Pages: publish each approved reel to the Page of its account (210.11).

Called from publish_due.py; a reel goes to the Page next to its Instagram
account (ig_en → Trubbo, ig_skcz → Trubbo SK & CZ). Carousels stay Instagram
only. Uses the Pages Reels API (start → hosted file_url upload → finish).

- Tokens: env FB_PAGE_TOKEN_EN / FB_PAGE_TOKEN_SKCZ (GitHub secrets). Page
  tokens derived from a long-lived user token do not expire. A due reel
  without a token fails the run, same as Instagram.
- Idempotent: a reel whose caption is already a recent Page reel's
  description counts as published.

One-time setup, after FB_USER_TOKEN (long-lived, from the Access Token Tool)
is in the root .env:

    uv run --no-sync python apps/social-studio/scripts/fb_pages.py --setup

writes FB_PAGE_TOKEN_* to .env and to GitHub secrets. Token values are never
printed.
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://graph.facebook.com/v26.0"
UPLOAD = "https://rupload.facebook.com/video-upload/v26.0"
# Page name on Facebook → env suffix, per Instagram account of the manifest.
PAGES = {"ig_en": ("Trubbo", "EN"), "ig_skcz": ("Trubbo SK & CZ", "SKCZ")}


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
    return os.environ.get(f"FB_PAGE_TOKEN_{PAGES[account][1]}") or None


def recent_descriptions(token: str) -> tuple[str, set[str]]:
    page = call("GET", "me", token, fields="id")["id"]
    reels = call("GET", f"{page}/video_reels", token, fields="description", limit=25)
    return page, {r.get("description", "").strip() for r in reels.get("data", [])}


def publish_reel(post: dict, page: str, token: str) -> str:
    video = next(u for u in post["media_urls"] if u.endswith(".mp4"))
    vid = call("POST", f"{page}/video_reels", token, upload_phase="start")["video_id"]
    req = urllib.request.Request(
        f"{UPLOAD}/{vid}",
        method="POST",
        headers={"Authorization": f"OAuth {token}", "file_url": video},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            if not json.load(resp).get("success"):
                raise RuntimeError(f"reel {vid}: upload not accepted")
    except urllib.error.HTTPError as e:
        raise RuntimeError(
            f"upload {vid}: {e.code} {e.read().decode()[:500]}"
        ) from None
    call(
        "POST",
        f"{page}/video_reels",
        token,
        upload_phase="finish",
        video_id=vid,
        video_state="PUBLISHED",
        description=post["caption"],
    )
    for _ in range(30):  # processing usually takes under a minute
        status = call("GET", vid, token, fields="status")["status"]
        if status.get("video_status") == "error":
            raise RuntimeError(f"reel {vid}: {json.dumps(status)[:300]}")
        if status.get("publishing_phase", {}).get("status") == "complete":
            return call("GET", vid, token, fields="permalink_url").get(
                "permalink_url", vid
            )
        time.sleep(10)
    raise RuntimeError(f"reel {vid}: not published after 5 min")


def check() -> None:
    for account, (name, _) in PAGES.items():
        token = token_for(account)
        if not token:
            print(f"fb {account}: no token")
            continue
        me = call("GET", "me", token, fields="id,name")
        mark = "" if me["name"] == name else f" (expected {name})"
        print(f"fb {account}: Page {me['name']}{mark}")


def setup() -> None:
    from dotenv import find_dotenv, load_dotenv, set_key

    env = find_dotenv(usecwd=True)
    load_dotenv(env)
    user = os.environ.get("FB_USER_TOKEN")
    if not user:
        sys.exit("FB_USER_TOKEN missing in .env")
    pages = call("GET", "me/accounts", user, fields="name,access_token", limit=50)
    by_name = {p["name"]: p["access_token"] for p in pages.get("data", [])}
    for name, suffix in PAGES.values():
        key = f"FB_PAGE_TOKEN_{suffix}"
        if name not in by_name:
            print(f"{key}: Page {name!r} not granted (got {sorted(by_name)})")
            continue
        set_key(env, key, by_name[name], quote_mode="never")
        subprocess.run(
            ["gh", "secret", "set", key], input=by_name[name].encode(), check=True
        )
        print(f"{key}: Page {name} saved to .env and GitHub secrets")


if __name__ == "__main__":
    setup() if "--setup" in sys.argv else check()
