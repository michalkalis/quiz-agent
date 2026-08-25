"""#166 follow-up 1 — Bedrock verifier with its own search loop, D21b eval.

Architecture (founder 2026-08-25): Tavily search -> download FULL pages
(Tavily Extract) -> code-side passage extraction (a cheap Bedrock model
proposes keywords, code pulls matching passages) -> Bedrock judge. No
Anthropic API anywhere in this experiment (Bedrock + Tavily only).

Why full pages: the old cheap variant (snippets only) had recall 0/6 resp.
4-5/7 — q48/q95-class errors are architecturally out of snippet reach (the
truth sits mid-page on Wikipedia, snippets even repeat the error). Source
trust follows the founder policy: Wikipedia first, then domain authorities,
low-trust aggregators never used as ground truth.

Gate: validation on the founder 7-error reference (q03/q32/q48/q63/q81/
q89/q95; q18 excluded) BEFORE any pipeline deployment. This script only
evaluates — it ships nothing.

Phases (durable JSONL, rerun skips done qids/URLs):

    uv run --no-sync python scripts/bedrock_verifier_eval_166.py wikisearch
    uv run --no-sync python scripts/bedrock_verifier_eval_166.py fetch
    uv run --no-sync python scripts/bedrock_verifier_eval_166.py keywords
    uv run --no-sync python scripts/bedrock_verifier_eval_166.py judge
    uv run --no-sync python scripts/bedrock_verifier_eval_166.py report

Run from apps/quiz-pack-api/ (.env loaded via quiz_shared).
"""

import argparse
import asyncio
import datetime
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_shared.paths import load_dotenv_from_ancestors  # noqa: E402

load_dotenv_from_ancestors(Path(__file__).resolve())

from factcheck_eval_166 import (  # noqa: E402
    OUT_DIR as EVAL_DIR,
    append_jsonl,
    cmd_report,
    done_qids,
    load_questions,
)

OUT_DIR = EVAL_DIR.parent / "bedrock-verifier-166"

JUDGE_MODEL = "bedrock:global.anthropic.claude-sonnet-4-6"
KEYWORD_MODEL = "bedrock:global.anthropic.claude-haiku-4-5-20251001-v1:0"

# List prices USD/1M (Bedrock on-demand == Anthropic list; covered by AWS
# Activate credits in practice, recorded anyway for the report).
_PRICES = {
    JUDGE_MODEL: (3.00, 15.00),
    KEYWORD_MODEL: (1.00, 5.00),
}
_TAVILY_CENTS_PER_ADVANCED_SEARCH = 1.6
# Tavily Extract: 1 credit / 5 successful basic extractions, $0.008/credit.
_TAVILY_CENTS_PER_EXTRACT = 0.16

URLS_PER_QUESTION = 6
PAGE_CHAR_CAP = 60_000
LEAD_CHARS = 700
WINDOW_CHARS = 350
PASSAGE_CAP_PER_PAGE = 6_000
# Bedrock on-demand throttles aggressively (ThrottlingException at 8).
CONCURRENCY = 3


def _chat(model: str):
    from quiz_shared.llm import factory

    return factory.chat_model(model, max_tokens=1024)


def _parse_json_obj(text: str) -> dict | None:
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return None


def _cost_cents(model: str, usage: dict) -> float:
    in_p, out_p = _PRICES[model]
    return round(
        (usage.get("input_tokens", 0) * in_p + usage.get("output_tokens", 0) * out_p)
        / 1_000_000
        * 100,
        3,
    )


def drop_errors(path: Path) -> None:
    """Error records are not 'done' — strip them so a rerun retries them."""
    if not path.exists():
        return
    good = [
        line
        for line in path.read_text().split("\n")
        if line and not json.loads(line).get("error")
    ]
    path.write_text("\n".join(good) + ("\n" if good else ""))


def load_jsonl(path: Path, key: str = "qid") -> dict:
    if not path.exists():
        return {}
    return {
        rec[key]: rec
        for rec in (json.loads(line) for line in path.read_text().split("\n") if line)
    }


# ------------------------------------------------------------ wikisearch ----

_WIKI_API = "https://en.wikipedia.org/w/api.php"
_HTTP_HEADERS = {
    "User-Agent": "quiz-agent-factcheck-eval/1.0 (michal.kalis@gmail.com)"
}


async def cmd_wikisearch() -> None:
    """Wikipedia's own free search API, no Tavily credits.

    The stored evidence.jsonl pool (2 open-web Tavily queries per question)
    often lacks the decisive Wikipedia article (q95: Chavannes bio). Founder
    trust policy is Wikipedia-first, so guarantee the pool has wiki candidates.
    (Originally a Tavily include_domains search; hit the account's
    pay-as-you-go limit mid-run, and the wiki API is free anyway.)
    """
    import httpx

    out_path = OUT_DIR / "wiki_search.jsonl"
    drop_errors(out_path)
    done = done_qids(out_path)
    questions = [q for q in load_questions() if q["qid"] not in done]
    print(f"wikisearch: {len(questions)} to do ({len(done)} stored)")

    sem = asyncio.Semaphore(4)

    async with httpx.AsyncClient(headers=_HTTP_HEADERS, timeout=20.0) as client:

        async def search(query: str, limit: int) -> list[dict]:
            res = await client.get(
                _WIKI_API,
                params={
                    "action": "query", "list": "search",
                    "srsearch": query, "srlimit": limit,
                    "format": "json", "formatversion": 2,
                },
            )
            res.raise_for_status()
            return res.json()["query"]["search"]

        async def one(q: dict) -> None:
            async with sem:
                # Two queries: (a) answer + entities — finds the answer's own
                # article; (b) question-only entities — finds articles for the
                # PREMISE entities (v1 miss: q63's pool was all Endgame pages,
                # never Spider-Man: Brand New Day, so the wrong "20 days"
                # premise had no evidence).
                q_entities = " ".join(
                    dict.fromkeys(
                        re.findall(
                            r"\b(?:[A-Z][\w'’:-]+(?:\s+[A-Z][\w'’:-]+)+)",
                            q["question"],
                        )
                        + re.findall(r"[\"'“]([^\"'”]{4,60})[\"'”]", q["question"])
                        + _YEAR_RE.findall(q["question"])
                    )
                )
                queries = [
                    " ".join(dict.fromkeys([q["answer"]] + _auto_keywords(q)))[:280],
                ]
                if q_entities:
                    queries.append(q_entities[:280])
                hits: list[dict] = []
                try:
                    for i, query in enumerate(queries):
                        for j, h in enumerate(await search(query, 4)):
                            hits.append(
                                {
                                    "url": "https://en.wikipedia.org/wiki/"
                                    + h["title"].replace(" ", "_"),
                                    "title": h["title"],
                                    "score": 1.0 / (j + 1),
                                }
                            )
                except Exception as e:
                    append_jsonl(out_path, {"qid": q["qid"], "error": str(e)})
                    print(f"  {q['qid']} ERROR {e}")
                    return
                seen: dict[str, dict] = {}
                for h in hits:
                    if h["url"] not in seen or h["score"] > seen[h["url"]]["score"]:
                        seen[h["url"]] = h
                append_jsonl(
                    out_path, {"qid": q["qid"], "results": list(seen.values())}
                )
                print(f"  {q['qid']} {len(seen)} wiki hits")

        await asyncio.gather(*(one(q) for q in questions))
    print(f"wiki search -> {out_path}")


# ----------------------------------------------------------------- fetch ----

def _url_pool() -> dict[str, list[dict]]:
    """Per-question ranked URL candidates: wiki search + stored evidence.

    Rank: Wikipedia > high credibility > medium; low-trust aggregators are
    dropped entirely (founder: never a basis for truth).
    """
    from app.sourcing.web_search_source import classify_credibility

    evidence = load_jsonl(EVAL_DIR / "evidence.jsonl")
    wiki = load_jsonl(OUT_DIR / "wiki_search.jsonl")

    pool: dict[str, list[dict]] = {}
    for q in load_questions():
        qid = q["qid"]
        cands: dict[str, dict] = {}
        for r in (wiki.get(qid) or {}).get("results", []):
            url = r.get("url") or ""
            if url:
                cands[url] = {"url": url, "tier": "wiki", "score": r.get("score") or 0}
        for s in (evidence.get(qid) or {}).get("searches", []):
            for r in s.get("results", []):
                url = r.get("url") or ""
                if not url or url in cands:
                    continue
                tier = (
                    "wiki" if "wikipedia.org" in url else classify_credibility(url)
                )
                if tier == "low":
                    continue
                cands[url] = {"url": url, "tier": tier, "score": r.get("score") or 0}
        rank = {"wiki": 0, "high": 1, "medium": 2}
        ranked = sorted(
            cands.values(), key=lambda c: (rank[c["tier"]], -c["score"])
        )
        pool[qid] = ranked[:URLS_PER_QUESTION]
    return pool


_TAG_STRIP_RE = re.compile(
    r"<(script|style|nav|header|footer|noscript)[^>]*>.*?</\1>",
    re.DOTALL | re.IGNORECASE,
)
_TAG_RE = re.compile(r"<[^>]+>")


def html_to_text(html: str) -> str:
    """Naive full-page HTML -> text; good enough for keyword-window passage
    extraction (Wikipedia pages go through the extracts API instead)."""
    import html as html_mod

    text = _TAG_STRIP_RE.sub(" ", html)
    text = re.sub(r"</(p|div|li|h[1-6]|tr|br)>", "\n", text, flags=re.IGNORECASE)
    text = _TAG_RE.sub(" ", text)
    return _normalize(html_mod.unescape(text))


async def cmd_fetch() -> None:
    """Full page text for every pooled URL (global URL cache): Wikipedia
    articles via the free extracts API (clean plaintext), the rest by plain
    HTTP GET + tag stripping. No Tavily credits (account hit its
    pay-as-you-go limit; download is free anyway)."""
    import httpx

    out_path = OUT_DIR / "pages.jsonl"
    drop_errors(out_path)
    have = set(load_jsonl(out_path, key="url"))
    wanted: list[str] = []
    for urls in _url_pool().values():
        for c in urls:
            if c["url"] not in have and c["url"] not in wanted:
                wanted.append(c["url"])
    print(f"fetch: {len(wanted)} URLs to do ({len(have)} cached)")

    # Wikipedia's API 429s hard at parallel bursts — serialize and back off.
    sem = asyncio.Semaphore(2)

    async with httpx.AsyncClient(
        headers=_HTTP_HEADERS, timeout=25.0, follow_redirects=True
    ) as client:

        async def get_with_backoff(*args, **kwargs):
            delay = 5.0
            for attempt in range(6):
                res = await client.get(*args, **kwargs)
                if res.status_code != 429:
                    return res
                await asyncio.sleep(delay)
                delay *= 2
            return res

        async def one(url: str) -> None:
            async with sem:
                await asyncio.sleep(0.3)
                try:
                    if "wikipedia.org/wiki/" in url:
                        title = url.rsplit("/wiki/", 1)[1].replace("_", " ")
                        res = await get_with_backoff(
                            _WIKI_API,
                            params={
                                "action": "query", "prop": "extracts",
                                "explaintext": 1, "redirects": 1,
                                "titles": title, "format": "json",
                                "formatversion": 2,
                            },
                        )
                        res.raise_for_status()
                        pages = res.json()["query"]["pages"]
                        content = pages[0].get("extract") or ""
                    else:
                        res = await get_with_backoff(url)
                        res.raise_for_status()
                        content = html_to_text(res.text)
                except Exception as e:
                    append_jsonl(out_path, {"url": url, "error": str(e)[:300]})
                    print(f"  ERR {url}: {str(e)[:80]}")
                    return
                if not content.strip():
                    append_jsonl(out_path, {"url": url, "error": "empty_content"})
                    print(f"  EMPTY {url}")
                    return
                append_jsonl(out_path, {"url": url, "content": content[:PAGE_CHAR_CAP]})
                print(f"  ok {url} ({len(content)} chars)")

        await asyncio.gather(*(one(u) for u in wanted))
    print(f"pages -> {out_path}")


# -------------------------------------------------------------- keywords ----

_KEYWORD_PROMPT = """A trivia question-answer pair must be fact-checked against full web pages. Your only job: list short search strings so code can locate the relevant passages inside those pages.

QUESTION: {question}
CLAIMED ANSWER: {claimed_answer}

Break the pair into its checkable factual claims — the claimed answer AND every factual premise inside the question (names, dates, years, counts, titles, superlatives, nationalities, roles). For each claim give 2-4 short literal strings (1-3 words each: surnames, work titles, years as digits, key nouns) likely to appear verbatim near the relevant passage on a source page. Prefer distinctive strings over common words.

Reply with ONLY JSON:
{{"claims": [{{"claim": "...", "keywords": ["...", "..."]}}]}}"""


async def cmd_keywords() -> None:
    """Cheap Bedrock model proposes per-question extraction keywords."""
    from quiz_shared.llm import factory

    out_path = OUT_DIR / "keywords.jsonl"
    drop_errors(out_path)
    done = done_qids(out_path)
    questions = [q for q in load_questions() if q["qid"] not in done]
    print(f"keywords[{KEYWORD_MODEL}]: {len(questions)} to do ({len(done)} stored)")

    model = _chat(KEYWORD_MODEL)
    sem = asyncio.Semaphore(CONCURRENCY)

    async def one(q: dict) -> None:
        async with sem:
            prompt = _KEYWORD_PROMPT.format(
                question=q["question"], claimed_answer=q["answer"]
            )
            try:
                resp = await model.ainvoke(prompt)
            except Exception as e:
                append_jsonl(out_path, {"qid": q["qid"], "error": str(e)})
                print(f"  {q['qid']} ERROR {e}")
                return
            data = _parse_json_obj(factory.message_text(resp)) or {}
            usage = getattr(resp, "usage_metadata", None) or {}
            append_jsonl(
                out_path,
                {
                    "qid": q["qid"],
                    "claims": data.get("claims", []),
                    "llm_cost_cents": _cost_cents(KEYWORD_MODEL, usage),
                },
            )
            print(f"  {q['qid']} {len(data.get('claims', []))} claims")

    await asyncio.gather(*(one(q) for q in questions))
    print(f"keywords -> {out_path}")


# ---------------------------------------------------- passage extraction ----

_YEAR_RE = re.compile(r"\b(1[89]\d{2}|20\d{2})\b")


def _auto_keywords(q: dict) -> list[str]:
    """Deterministic fallback keywords so extraction never rides on the
    keyword model alone: capitalized tokens + years + quoted titles."""
    text = f"{q['question']} {q['answer']}"
    kws = set(_YEAR_RE.findall(text))
    kws.update(m.group(0) for m in re.finditer(r"\b[A-Z][a-z]{3,}\b", text))
    kws.update(re.findall(r"[\"'“]([^\"'”]{4,40})[\"'”]", text))
    return list(kws)


def _normalize(text: str) -> str:
    return re.sub(r"[ \t]+", " ", re.sub(r"\n{3,}", "\n\n", text))


def extract_passages(page: str, keywords: list[str]) -> str:
    """Windows around keyword hits, merged, plus the page lead. Pure code."""
    text = _normalize(page)
    spans: list[tuple[int, int]] = [(0, min(LEAD_CHARS, len(text)))]
    low = text.lower()
    for kw in keywords:
        k = kw.strip().lower()
        if len(k) < 3:
            continue
        hits: list[int] = []
        start = 0
        while len(hits) < 40:
            i = low.find(k, start)
            if i == -1:
                break
            hits.append(i)
            start = i + len(k)
        # v1 took the FIRST 5 hits only, so a decisive section deep in the
        # page (q63: "Fastest to $2 billion") never made it into the
        # passages. Spread the kept hits across the whole page instead.
        if len(hits) > 5:
            step = (len(hits) - 1) / 4
            hits = [hits[round(i * step)] for i in range(5)]
        for i in hits:
            spans.append((max(0, i - WINDOW_CHARS), min(len(text), i + WINDOW_CHARS)))
    spans.sort()
    merged: list[list[int]] = []
    for s, e in spans:
        if merged and s <= merged[-1][1] + 50:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    out: list[str] = []
    total = 0
    for s, e in merged:
        if total >= PASSAGE_CAP_PER_PAGE:
            break
        chunk = text[s:e].strip()
        out.append(("…" if s > 0 else "") + chunk + ("…" if e < len(text) else ""))
        total += len(chunk)
    return "\n[…]\n".join(out)


# ----------------------------------------------------------------- judge ----

_JUDGE_PROMPT = """You are an adversarial fact-checker for a trivia quiz. Today is {today}. Your job is to find problems with a question-answer pair, not to confirm it. The question may have been written months ago: superlative or "only/most recent/current" claims can have been overtaken by newer events. Both the claimed answer AND every factual premise stated inside the question must be correct.

QUESTION: {question}
CLAIMED ANSWER: {claimed_answer}
TOPIC: {topic}

Below are passages extracted from FULL source pages (not search snippets), grouped per source. Source trust hierarchy, in strict order: (1) Wikipedia and the sources Wikipedia itself cites, (2) domain authorities (e.g. IMDb for film), (3) other reputable media. Where sources disagree, the higher tier wins. Never base a verdict on a low-credibility aggregator.

{evidence}

Judge ONLY from the evidence above plus well-established common knowledge. Actively look for contradictions: a different record-holder, a different count, date, role or nationality, a newer event that supersedes the claim, or a premise in the question that the evidence contradicts.

Check every specific number, year, date, nationality and role the question asserts against the evidence — including incidental ones that are not the answer itself. Example: a question opening "In 2025's <film>..." is a fact_error if the evidence shows the film premiered in 2026; "American engineers" is a fact_error if the evidence shows one inventor was Swiss.

Calibration: report a problem ONLY when a high-tier source directly and materially contradicts a specific claim in the pair — materially means a listener who knows the truth would call the question WRONG, not merely imprecise. Do NOT flag any of these (they are "ok"):
- rounded or approximate figures within ~15% of the sourced value, or wording like "roughly/about/nearly" covering the difference (e.g. "roughly 300 bones" vs a sourced 270)
- a generic term where sources use a more specific one, or vice versa (a "chocolate bar" vs "candy bar"; "stone" for limestone)
- imprecise-but-defensible phrasing, simplified storytelling framing, or a detail that is defensible under ANY reasonable reading of the sources
- present tense for a record that still stood when the question was written; extra detail the sources add beyond the answer
- a technicality or trivia-lore simplification a pub-quiz host would wave through
DO still flag material errors: a wrong person, role (producing vs performing), nationality, year, title, or record-holder; a premise event dated to the wrong year; a superlative that a higher-tier source disproves. A quizmaster reads your verdict and drops the question — a wrong drop wastes a good question, a wrong keep ships an error; both matter. If you are torn between "ok" and a flag on a wording-level issue, answer "ok".

Give exactly one verdict:
- "fact_error" — the claimed answer is factually wrong, or the question asserts something false
- "logic_flaw" — the question is ambiguous, self-contradictory, or has multiple defensible answers
- "stale" — the pair was true once but has been superseded by newer events
- "ok" — the evidence is consistent with the pair and you found no problem
- "insufficient_evidence" — the evidence neither supports nor contradicts the pair well enough to judge

Reply with ONLY a single JSON object:
{{"verdict": "ok|fact_error|logic_flaw|stale|insufficient_evidence", "confidence": "high|medium|low", "note": "one-sentence justification citing the decisive source URL", "correct_answer": "the actual answer if the claimed one is wrong, else null"}}"""


def _build_evidence(qid: str, q: dict, pool: dict, pages: dict, keywords: dict) -> str:
    claims = (keywords.get(qid) or {}).get("claims", [])
    kws = [k for c in claims for k in c.get("keywords", [])] + _auto_keywords(q)
    blocks = []
    for i, cand in enumerate(pool.get(qid, []), 1):
        page = pages.get(cand["url"]) or {}
        content = page.get("content")
        if not content:
            continue
        passages = extract_passages(content, kws)
        tier = {"wiki": "wikipedia", "high": "high", "medium": "medium"}[cand["tier"]]
        blocks.append(
            f"[{i}] {cand['url']} [credibility: {tier}]\n{passages}"
        )
    if not blocks:
        return "SOURCES: (none — no page could be fetched)"
    return "SOURCES:\n\n" + "\n\n".join(blocks)


async def cmd_judge() -> None:
    from quiz_shared.llm import factory

    pool = _url_pool()
    pages = load_jsonl(OUT_DIR / "pages.jsonl", key="url")
    keywords = load_jsonl(OUT_DIR / "keywords.jsonl")
    kw_cost = {
        qid: rec.get("llm_cost_cents", 0) for qid, rec in keywords.items()
    }

    out_path = OUT_DIR / "judge_bedrock_sonnet46.v2.jsonl"
    drop_errors(out_path)
    done = done_qids(out_path)
    questions = [q for q in load_questions() if q["qid"] not in done]
    print(f"judge[{JUDGE_MODEL}]: {len(questions)} to do ({len(done)} stored)")

    model = _chat(JUDGE_MODEL)
    today = datetime.date.today().isoformat()
    sem = asyncio.Semaphore(CONCURRENCY)

    async def one(q: dict) -> None:
        async with sem:
            prompt = _JUDGE_PROMPT.format(
                today=today,
                question=q["question"],
                claimed_answer=q["answer"],
                topic=q["topic"],
                evidence=_build_evidence(q["qid"], q, pool, pages, keywords),
            )
            data: dict = {}
            usage: dict = {}
            raw = ""
            for attempt in range(2):  # v1: one q48 response was unparseable
                try:
                    resp = await model.ainvoke(prompt)
                except Exception as e:
                    append_jsonl(out_path, {"qid": q["qid"], "error": str(e)})
                    print(f"  {q['qid']} ERROR {e}")
                    return
                raw = factory.message_text(resp)
                data = _parse_json_obj(raw) or {}
                u = getattr(resp, "usage_metadata", None) or {}
                usage = {
                    k: usage.get(k, 0) + u.get(k, 0)
                    for k in ("input_tokens", "output_tokens")
                }
                if data.get("verdict"):
                    break
            if not data.get("verdict"):
                data = {"verdict": "unparseable", "note": raw[:300]}
            append_jsonl(
                out_path,
                {
                    "qid": q["qid"],
                    "arm": q["arm"],
                    "verdict": data.get("verdict", "unparseable"),
                    "confidence": data.get("confidence"),
                    "note": data.get("note"),
                    "correct_answer": data.get("correct_answer"),
                    "llm_cost_cents": _cost_cents(JUDGE_MODEL, usage)
                    + kw_cost.get(q["qid"], 0),
                    # 2 stored advanced searches (evidence.jsonl); wiki
                    # search + page download are free (Wikipedia API / HTTP).
                    "tavily_cost_cents": 2 * _TAVILY_CENTS_PER_ADVANCED_SEARCH,
                    "input_tokens": usage.get("input_tokens"),
                    "output_tokens": usage.get("output_tokens"),
                },
            )
            print(f"  {q['qid']} {data.get('verdict')}")

    await asyncio.gather(*(one(q) for q in questions))
    print(f"verdicts -> {out_path}")


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("wikisearch", "fetch", "keywords", "judge"):
        sub.add_parser(name)
    r = sub.add_parser("report")
    r.add_argument("paths", nargs="*")
    args = ap.parse_args()

    if args.cmd == "wikisearch":
        asyncio.run(cmd_wikisearch())
    elif args.cmd == "fetch":
        asyncio.run(cmd_fetch())
    elif args.cmd == "keywords":
        asyncio.run(cmd_keywords())
    elif args.cmd == "judge":
        asyncio.run(cmd_judge())
    else:
        cmd_report(args.paths or [str(OUT_DIR / "judge_bedrock_sonnet46.v2.jsonl")])


if __name__ == "__main__":
    main()
