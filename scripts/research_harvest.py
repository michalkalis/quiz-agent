#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["httpx>=0.27", "google-play-scraper>=1.2.7"]
# ///
"""Mass-input harvester for the /mass-research skill.

Pulls hundreds to thousands of real user inputs (App Store reviews, Google Play
reviews, Reddit posts + comments, Hacker News) into one JSONL corpus, so a
research conclusion rests on counted evidence instead of a handful of quotes.

    uv run scripts/research_harvest.py harvest docs/research/plans/<slug>.json
    uv run scripts/research_harvest.py filter  docs/research/plans/<slug>.json
    uv run scripts/research_harvest.py batches docs/research/plans/<slug>.json --size 120
    uv run scripts/research_harvest.py stats   docs/research/plans/<slug>.json
    uv run scripts/research_harvest.py tally   docs/research/plans/<slug>.json

Output lands in docs/artifacts/research/<slug>/ (gitignored): corpus.jsonl,
apps.json (competitor apps + their in-app purchases with prices),
relevant.jsonl, batches/batch-NNN.md. Re-running `harvest` only adds new items.
A source that fails is reported in harvest-log.json, never silently skipped.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from collections import Counter
from html import unescape
from pathlib import Path

import httpx

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15"
ROOT = Path(__file__).resolve().parent.parent
ARCTIC = "https://arctic-shift.photon-reddit.com/api"


class Corpus:
    def __init__(self, out: Path):
        self.path = out / "corpus.jsonl"
        self.seen: set[str] = set()
        if self.path.exists():
            for line in self.path.open():
                self.seen.add(json.loads(line)["id"])
        self.fh = self.path.open("a")
        self.added = 0

    def add(self, **item) -> bool:
        text = (item.get("text") or "").strip()
        if not text or item["id"] in self.seen:
            return False
        self.seen.add(item["id"])
        item["text"] = text
        self.fh.write(json.dumps(item, ensure_ascii=False) + "\n")
        self.added += 1
        return True


def get_json(client: httpx.Client, url: str, pause: float = 2.0, **params):
    """GET with backoff. Archive APIs answer 422/429 when asked too fast - wait and retry, don't hammer."""
    for attempt in range(5):
        r = client.get(url, params=params or None)
        if r.status_code in (422, 429) or r.status_code >= 500:
            time.sleep(pause * (attempt + 1))
            continue
        r.raise_for_status()
        return r.json()
    r.raise_for_status()


# ---------- App Store ----------


def appstore_find_apps(client, cfg) -> dict[str, dict]:
    apps: dict[str, dict] = {}
    country = cfg.get("search_country", "us")
    for term in cfg.get("search_terms", []):
        data = get_json(
            client,
            "https://itunes.apple.com/search",
            term=term,
            entity="software",
            country=country,
            limit=cfg.get("per_term", 25),
        )
        for a in data.get("results", []):
            apps.setdefault(
                str(a["trackId"]),
                {
                    "id": str(a["trackId"]),
                    "name": a["trackName"],
                    "found_by": term,
                    "ratings": a.get("userRatingCount", 0),
                    "rating": a.get("averageUserRating"),
                    "price": a.get("formattedPrice"),
                    "genre": a.get("primaryGenreName"),
                },
            )
    for app_id in map(str, cfg.get("app_ids", [])):
        if app_id in apps:
            continue
        res = get_json(
            client, "https://itunes.apple.com/lookup", id=app_id, country=country
        ).get("results", [])
        if res:
            a = res[0]
            apps[app_id] = {
                "id": app_id,
                "name": a["trackName"],
                "found_by": "plan",
                "ratings": a.get("userRatingCount", 0),
                "rating": a.get("averageUserRating"),
                "price": a.get("formattedPrice"),
                "genre": a.get("primaryGenreName"),
            }
    pinned = set(map(str, cfg.get("app_ids", [])))
    ranked = sorted(apps.values(), key=lambda a: (a["id"] not in pinned, -a["ratings"]))
    return {a["id"]: a for a in ranked[: cfg.get("max_apps", 30)]}


def appstore_iaps(client, app_id: str, country: str) -> list[dict]:
    """In-app purchases listed on the public App Store page (name + price), read from the rendered HTML."""
    html = client.get(
        f"https://apps.apple.com/{country}/app/id{app_id}", follow_redirects=True
    ).text
    price = r"((?:[$€£]\s?[\d.,]+)|(?:[\d.,]+\s?(?:€|Kč|zł)))"
    pairs = re.findall(
        rf'class="text-pair[^"]*"><span>([^<]+)</span>\s*<span>{price}</span>', html
    )
    pairs += re.findall(
        rf"<p[^>]*>([^<]+)</p></span>\s*</div>\s*<p[^>]*>{price}</p>", html
    )
    seen, out = set(), []
    for name, cost in pairs:
        if (name, cost) not in seen:
            seen.add((name, cost))
            out.append({"name": unescape(name).strip(), "price": cost})
    return out


def appstore_reviews(client, corpus, app, countries, pages) -> int:
    n = 0
    for country in countries:
        for sort in ("mostrecent", "mosthelpful"):
            for page in range(1, pages + 1):
                url = (
                    f"https://itunes.apple.com/{country}/rss/customerreviews/page={page}"
                    f"/id={app['id']}/sortby={sort}/json"
                )
                try:
                    entries = get_json(client, url).get("feed", {}).get("entry", [])
                except (httpx.HTTPError, json.JSONDecodeError):
                    break
                if isinstance(entries, dict):
                    entries = [entries]
                fresh = 0
                for e in entries:
                    if "im:rating" not in e:
                        continue
                    fresh += corpus.add(
                        id=f"as-{e['id']['label']}",
                        source="appstore",
                        app=app["name"],
                        country=country,
                        rating=int(e["im:rating"]["label"]),
                        date=e.get("updated", {}).get("label", "")[:10],
                        title=e.get("title", {}).get("label", ""),
                        text=e.get("content", {}).get("label", ""),
                        votes=int(e.get("im:voteSum", {}).get("label", 0) or 0),
                        url=f"https://apps.apple.com/{country}/app/id{app['id']}",
                    )
                n += fresh
                if len(entries) < 40:
                    break
    return n


# ---------- Google Play ----------


def play_reviews(corpus, cfg, log) -> None:
    from google_play_scraper import Sort, reviews, search

    ids: dict[str, str] = {i: i for i in cfg.get("app_ids", [])}
    for term in cfg.get("search_terms", []):
        try:
            for a in search(
                term, lang="en", country="us", n_hits=cfg.get("per_term", 10)
            ):
                if a.get("appId"):
                    ids.setdefault(a["appId"], a.get("title") or a["appId"])
        except Exception as e:  # noqa: BLE001 — unofficial scraper, any failure is reported
            log["errors"].append(f"play search '{term}': {e!r}")
    for app_id, name in list(ids.items())[: cfg.get("max_apps", 20)]:
        for lang, country in cfg.get("locales", [["en", "us"]]):
            token, got = None, 0
            try:
                while got < cfg.get("count", 600):
                    batch, token = reviews(
                        app_id,
                        lang=lang,
                        country=country,
                        sort=Sort.MOST_RELEVANT,
                        count=200,
                        continuation_token=token,
                    )
                    if not batch:
                        break
                    for r in batch:
                        got += 1
                        corpus.add(
                            id=f"gp-{r['reviewId']}",
                            source="play",
                            app=name,
                            country=country,
                            rating=r.get("score"),
                            date=str(r.get("at"))[:10],
                            title="",
                            text=r.get("content") or "",
                            votes=r.get("thumbsUpCount", 0),
                            url=f"https://play.google.com/store/apps/details?id={app_id}",
                        )
                    if token is None or getattr(token, "token", None) is None:
                        break
            except Exception as e:  # noqa: BLE001
                log["errors"].append(f"play reviews {app_id}/{lang}: {e!r}")
            log["play"][f"{name} ({lang})"] = got


# ---------- Reddit (Arctic Shift archive) + Hacker News ----------


def _reddit_add(corpus, sub: str, p: dict) -> None:
    text = p.get("body") or f"{p.get('title', '')}\n{p.get('selftext', '')}"
    link = (
        p.get("permalink")
        or f"/comments/{str(p.get('link_id', p['id'])).removeprefix('t3_')}"
    )
    corpus.add(
        id=f"rd-{p['id']}", source="reddit", app=f"r/{sub}", country="", rating=None,
        date=time.strftime("%Y-%m-%d", time.gmtime(int(p["created_utc"]))),
        title=p.get("title", ""), text=text[:4000], votes=p.get("score", 0),
        url="https://www.reddit.com" + link,
    )  # fmt: skip


def reddit(client, corpus, cfg, log) -> None:
    """Threads whose TITLE matches a term, plus their comments.

    The archive times out on full-text comment search, so threads are found by title
    (one or two words per term work best) and their comments fetched by thread id.
    """
    for sub in cfg.get("subreddits", []):
        for term in cfg.get("title_terms", []):
            got = 0
            try:
                found = get_json(client, f"{ARCTIC}/posts/search", pause=15,
                                 subreddit=sub, title=term, limit=cfg.get("posts_per_term", 40))  # fmt: skip
                time.sleep(2.5)
                for post in found.get("data") or []:
                    _reddit_add(corpus, sub, post)
                    got += 1
                    if not post.get("num_comments"):
                        continue
                    tree = get_json(client, f"{ARCTIC}/comments/search", pause=15,
                                    link_id=post["id"], limit=cfg.get("comments_per_post", 100))  # fmt: skip
                    time.sleep(1.5)
                    for c in tree.get("data") or []:
                        _reddit_add(corpus, sub, c)
                        got += 1
            except httpx.HTTPError as e:
                log["errors"].append(f"reddit r/{sub} '{term}': {e!r}")
            log["reddit"][f"r/{sub} '{term}'"] = got
            print(f"  reddit · r/{sub} '{term}' {got}", flush=True)


def hackernews(client, corpus, cfg, log) -> None:
    for q in cfg.get("queries", []):
        got = 0
        for page in range(cfg.get("pages", 3)):
            try:
                hits = get_json(
                    client,
                    "https://hn.algolia.com/api/v1/search",
                    query=q,
                    tags="(story,comment)",
                    hitsPerPage=100,
                    page=page,
                ).get("hits", [])
            except httpx.HTTPError as e:
                log["errors"].append(f"hn '{q}': {e!r}")
                break
            for h in hits:
                got += 1
                text = re.sub(
                    r"<[^>]+>",
                    " ",
                    h.get("comment_text")
                    or h.get("story_text")
                    or h.get("title")
                    or "",
                )
                corpus.add(
                    id=f"hn-{h['objectID']}",
                    source="hn",
                    app="Hacker News",
                    country="",
                    rating=None,
                    date=(h.get("created_at") or "")[:10],
                    title=h.get("title") or h.get("story_title") or "",
                    text=text[:4000],
                    votes=h.get("points") or 0,
                    url=f"https://news.ycombinator.com/item?id={h['objectID']}",
                )
            if len(hits) < 100:
                break
        log["hn"][q] = got


# ---------- Commands ----------


def load(plan_path: str) -> tuple[dict, Path]:
    plan = json.loads(Path(plan_path).read_text())
    out = ROOT / "docs" / "artifacts" / "research" / plan["slug"]
    (out / "batches").mkdir(parents=True, exist_ok=True)
    (out / "coded").mkdir(exist_ok=True)
    return plan, out


def read_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.open()] if path.exists() else []


def cmd_harvest(plan, out, only: str | None = None) -> None:
    corpus = Corpus(out)
    log = {"appstore": {}, "play": {}, "reddit": {}, "hn": {}, "errors": []}
    log_path = out / "harvest-log.json"
    if (
        only
    ):  # re-run one source (e.g. after a rate limit) and keep the other sources' log
        plan = {k: v for k, v in plan.items() if k == only}
        if log_path.exists():
            log = json.loads(log_path.read_text()) | {only: {}, "errors": []}
    with httpx.Client(headers={"User-Agent": UA}, timeout=30) as client:
        if cfg := plan.get("appstore"):
            apps = appstore_find_apps(client, cfg)
            for app in apps.values():
                try:
                    app["iaps"] = appstore_iaps(
                        client, app["id"], cfg.get("iap_country", "us")
                    )
                except (httpx.HTTPError, json.JSONDecodeError) as e:
                    app["iaps"] = []
                    log["errors"].append(f"iap {app['name']}: {e!r}")
                log["appstore"][app["name"]] = appstore_reviews(
                    client,
                    corpus,
                    app,
                    cfg.get("countries", ["us"]),
                    cfg.get("pages", 10),
                )
                print(
                    f"  app store · {app['name'][:40]:40} +{log['appstore'][app['name']]}",
                    flush=True,
                )
            (out / "apps.json").write_text(
                json.dumps(list(apps.values()), indent=1, ensure_ascii=False)
            )
        if cfg := plan.get("play"):
            play_reviews(corpus, cfg, log)
        if cfg := plan.get("reddit"):
            reddit(client, corpus, cfg, log)
        if cfg := plan.get("hn"):
            hackernews(client, corpus, cfg, log)
    log["added_this_run"], log["corpus_total"] = corpus.added, len(corpus.seen)
    (out / "harvest-log.json").write_text(json.dumps(log, indent=1, ensure_ascii=False))
    print(
        f"added {corpus.added} · corpus {len(corpus.seen)} · errors {len(log['errors'])}"
    )
    for e in log["errors"]:
        print("  ERROR", e)


def cmd_iaps(plan, out) -> None:
    """Refresh in-app purchase lists in apps.json without re-harvesting reviews."""
    apps = json.loads((out / "apps.json").read_text())
    with httpx.Client(headers={"User-Agent": UA}, timeout=30) as client:
        for app in apps:
            app["iaps"] = appstore_iaps(
                client, app["id"], plan["appstore"].get("iap_country", "us")
            )
            print(f"  {app['name'][:40]:40} {len(app['iaps'])} purchases")
    (out / "apps.json").write_text(json.dumps(apps, indent=1, ensure_ascii=False))


def cmd_filter(plan, out) -> None:
    pattern = re.compile("|".join(plan["keywords"]), re.IGNORECASE)
    min_len = plan.get("min_chars", 40)
    items = read_jsonl(out / "corpus.jsonl")
    kept = [
        i
        for i in items
        if len(i["text"]) >= min_len
        and pattern.search(f"{i.get('title', '')} {i['text']}")
    ]
    with (out / "relevant.jsonl").open("w") as fh:
        for i in kept:
            fh.write(json.dumps(i, ensure_ascii=False) + "\n")
    print(f"relevant {len(kept)} of {len(items)}")


def cmd_batches(plan, out, size: int) -> None:
    items = read_jsonl(out / "relevant.jsonl")
    book = "\n".join(f"- `{c}` — {d}" for c, d in plan.get("codebook", {}).items())
    (out / "codebook.md").write_text(f"# Codebook · {plan['question']}\n\n{book}\n")
    for old in (out / "batches").glob("batch-*.md"):
        old.unlink()
    for n, start in enumerate(range(0, len(items), size), 1):
        lines = [f"# Batch {n} · question: {plan['question']}", ""]
        for i in items[start : start + size]:
            stars = f" · {i['rating']}★" if i.get("rating") else ""
            lines.append(
                f"## [{i['id']}] {i['source']} · {i['app']}{stars} · {i.get('date', '')}"
            )
            if i.get("title"):
                lines.append(f"**{i['title']}**")
            lines += [i["text"][:1500], ""]
        (out / "batches" / f"batch-{n:03d}.md").write_text("\n".join(lines))
    print(f"{len(items)} items in {-(-len(items) // size)} batches → {out / 'batches'}")


def cmd_stats(plan, out) -> None:
    items, rel = read_jsonl(out / "corpus.jsonl"), read_jsonl(out / "relevant.jsonl")
    print(f"corpus {len(items)} · relevant {len(rel)}")
    for label, rows in (("corpus by source", items), ("relevant by source", rel)):
        print(label, dict(Counter(i["source"] for i in rows)))
    print("top apps:", Counter(i["app"] for i in items).most_common(15))
    print("relevant by keyword:")
    for kw in plan["keywords"]:
        rx = re.compile(kw, re.IGNORECASE)
        print(f"  {kw:32} {sum(1 for i in rel if rx.search(i['text']))}")


def cmd_tally(plan, out) -> None:
    """Count the codes the coding subagents assigned (coded/batch-NNN.json) — numbers come from here, not from memory."""
    by_id = {i["id"]: i for i in read_jsonl(out / "relevant.jsonl")}
    rows, missing = [], []
    for n in range(1, len(list((out / "batches").glob("batch-*.md"))) + 1):
        f = out / "coded" / f"batch-{n:03d}.json"
        if not f.exists():
            missing.append(f.name)
            continue
        rows += [r for r in json.loads(f.read_text()) if r.get("id") in by_id]
    skip = set(
        plan.get("exclude_apps", [])
    )  # apps that slipped into the harvest but are not comparable
    rows = [r for r in rows if by_id[r["id"]]["app"] not in skip]
    on_topic = [r for r in rows if r.get("codes")]
    per_app: dict[str, Counter] = {}
    for r in on_topic:
        per_app.setdefault(by_id[r["id"]]["app"], Counter()).update(set(r["codes"]))
    codes, stance, quotes = Counter(), {}, {}
    themes = Counter(r["theme"].strip().lower() for r in on_topic if r.get("theme"))
    for r in on_topic:
        for c in set(r["codes"]):
            codes[c] += 1
            stance.setdefault(c, Counter())[r.get("sentiment", "neutral")] += 1
            if r.get("quote"):
                quotes.setdefault(c, []).append(
                    (by_id[r["id"]].get("votes") or 0, r["id"], r["quote"])
                )
    result = {
        "coded": len(rows),
        "on_topic": len(on_topic),
        "missing_batches": missing,
        "themes": themes.most_common(60),
        "by_app": {
            a: dict(c.most_common())
            for a, c in sorted(per_app.items(), key=lambda kv: -sum(kv[1].values()))
        },
        "sources_on_topic": dict(Counter(by_id[r["id"]]["source"] for r in on_topic)),
        "codes": [
            {
                "code": c,
                "count": n,
                "sentiment": dict(stance[c]),
                "quotes": [
                    {
                        "id": i,
                        "quote": q,
                        "url": by_id[i]["url"],
                        "app": by_id[i]["app"],
                    }
                    for _, i, q in sorted(quotes.get(c, []), reverse=True)[:6]
                ],
            }
            for c, n in codes.most_common()
        ],
    }
    (out / "tally.json").write_text(json.dumps(result, indent=1, ensure_ascii=False))
    print(
        f"coded {len(rows)} · on topic {len(on_topic)} · missing batches {missing or 'none'}"
    )
    for c in result["codes"]:
        print(f"  {c['count']:5}  {c['code']:40} {c['sentiment']}")


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "command", choices=["harvest", "filter", "batches", "stats", "tally", "iaps"]
    )
    ap.add_argument("plan")
    ap.add_argument("--size", type=int, default=120)
    ap.add_argument("--only", choices=["appstore", "play", "reddit", "hn"])
    args = ap.parse_args()
    plan, out = load(args.plan)
    if args.command == "harvest":
        cmd_harvest(plan, out, args.only)
    elif args.command == "filter":
        cmd_filter(plan, out)
    elif args.command == "batches":
        cmd_batches(plan, out, args.size)
    elif args.command == "iaps":
        cmd_iaps(plan, out)
    elif args.command == "tally":
        cmd_tally(plan, out)
    else:
        cmd_stats(plan, out)


if __name__ == "__main__":
    sys.exit(main())
