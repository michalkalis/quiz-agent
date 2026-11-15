"""Socials stats per channel, read-only (#210 — social marketing).

Run before a weekly batch to see what works:

    uv run --no-sync python apps/social-studio/scripts/stats.py [--top 5]

- Instagram: views, reach, likes, saves, shares per post (Instagram API with
  Instagram Login, tokens IG_TOKEN_* in the root .env).
- Facebook: reel views per Page (needs read_insights on FB_PAGE_TOKEN_*;
  without it the Page says so instead of failing).
- YouTube: views of the latest Shorts from the public channel feed (no key).
- TikTok: profile totals only (followers, likes, videos); per-video views
  are only in the TikTok app (Creator tools > Analytics).
Token values are never printed.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

from dotenv import find_dotenv, load_dotenv

IG = "https://graph.instagram.com/v26.0"
FB = "https://graph.facebook.com/v26.0"
YT = {"en": "UCI8_p0qGeO0em6OLcPSOyBQ", "skcz": "UCjAtfRR3aS2peUSVwaUhLZQ"}
TIKTOK = ["trubboapp", "trubboskcz"]
UA = {"User-Agent": "Mozilla/5.0 (Macintosh) AppleWebKit/605.1.15 Safari/605.1.15"}


def fetch(url: str) -> str:
    with urllib.request.urlopen(
        urllib.request.Request(url, headers=UA), timeout=30
    ) as r:
        return r.read().decode()


def graph(base: str, path: str, token: str, **params) -> dict:
    query = urllib.parse.urlencode({**params, "access_token": token})
    try:
        return json.loads(fetch(f"{base}/{path}?{query}"))
    except urllib.error.HTTPError as e:
        return {
            "error": json.loads(e.read().decode()).get("error", {}).get("message", "")
        }


def show(title: str, rows: list[tuple[int, str]], top: int) -> None:
    rows.sort(reverse=True)
    print(f"  total {sum(v for v, _ in rows)} views in {len(rows)} posts; top {top}:")
    for views, label in rows[:top]:
        print(f"    {views:>6}  {label}")


def instagram(top: int) -> None:
    for acc in ("IG_EN", "IG_SKCZ"):
        token = os.environ.get(f"IG_TOKEN_{acc}")
        if not token:
            print(f"Instagram {acc}: no token")
            continue
        me = graph(IG, "me", token, fields="username,followers_count")
        print(f"Instagram @{me.get('username')}: {me.get('followers_count')} followers")
        media = graph(IG, "me/media", token, fields="id,timestamp,caption", limit=100)
        rows, sums = [], {"likes": 0, "saved": 0, "shares": 0}
        for m in media.get("data", []):
            ins = graph(
                IG, f"{m['id']}/insights", token, metric="views,likes,saved,shares"
            )
            vals = {d["name"]: d["values"][0]["value"] for d in ins.get("data", [])}
            for k in sums:
                sums[k] += vals.get(k, 0)
            label = f"{m['timestamp'][:10]} {(m.get('caption') or '')[:60]!r}"
            rows.append((vals.get("views", 0), label))
        show(acc, rows, top)
        print(
            f"  likes {sums['likes']}, saves {sums['saved']}, shares {sums['shares']}"
        )


def facebook(top: int) -> None:
    for suffix in ("EN", "SKCZ"):
        token = os.environ.get(f"FB_PAGE_TOKEN_{suffix}")
        if not token:
            print(f"Facebook {suffix}: no token")
            continue
        me = graph(FB, "me", token, fields="name,followers_count")
        print(f"Facebook {me.get('name')}: {me.get('followers_count')} followers")
        reels = graph(
            FB, "me/video_reels", token, fields="id,created_time,description", limit=50
        )
        rows = []
        for r in reels.get("data", []):
            ins = graph(
                FB, f"{r['id']}/video_insights", token, metric="blue_reels_play_count"
            )
            if "error" in ins:
                print(f"  stats unreadable: {ins['error'][:90]}")
                break
            views = sum(d["values"][0]["value"] for d in ins.get("data", []))
            rows.append(
                (
                    views,
                    f"{r['created_time'][:10]} {(r.get('description') or '')[:60]!r}",
                )
            )
        else:
            show(suffix, rows, top)


def youtube(top: int) -> None:
    for name, channel in YT.items():
        feed = fetch(f"https://www.youtube.com/feeds/videos.xml?channel_id={channel}")
        entries = re.findall(
            r"<published>(.*?)</published>.*?<media:title>(.*?)</media:title>.*?views=\"(\d+)\"",
            feed,
            re.DOTALL,
        )
        print(f"YouTube {name} (latest {len(entries)} in the public feed)")
        show(name, [(int(v), f"{p[:10]} {t[:60]!r}") for p, t, v in entries], top)


def tiktok() -> None:
    for handle in TIKTOK:
        page = fetch(f"https://www.tiktok.com/@{handle}")
        got = {
            k: (re.findall(rf'"{k}":(\d+)', page) or ["?"])[0]
            for k in ("followerCount", "heartCount", "videoCount")
        }
        print(
            f"TikTok @{handle}: {got['followerCount']} followers, {got['heartCount']} likes, {got['videoCount']} videos"
        )


if __name__ == "__main__":
    load_dotenv(find_dotenv(usecwd=True))
    top = int(sys.argv[sys.argv.index("--top") + 1]) if "--top" in sys.argv else 5
    instagram(top)
    facebook(top)
    youtube(top)
    tiktok()
