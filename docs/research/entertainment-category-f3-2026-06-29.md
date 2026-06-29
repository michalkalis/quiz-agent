# F-3 — `entertainment` category: research + recommended build

**Issue:** #72 (question fun/engagement redesign) → post-Phase-6b follow-up **F-3**
**Date:** 2026-06-29 · **Founder scope decision:** GLOBAL pop-culture, **evergreen + current/viral**
**Status:** research only — build is gated on the founder's phasing decision (§6). No code changed.

---

## 1. TL;DR — the one decision

Entertainment splits cleanly into **two pipelines with very different cost**, and the research (ours and the industry's) agrees they should not be built as one:

| | **Evergreen** (famous films, music history, iconic actors) | **Current / viral** (trending now, this week's release) |
|---|---|---|
| Sourcing infra | **Already exists** — reuse OpenTriviaDB + Wikipedia + Tavily as-is | **Missing** — needs recency-aware Tavily (the deleted news path) |
| Expiry infra | None needed (facts don't go stale) | **Missing** — `expires_at`/`freshness_tag` are dormant; needs wiring + a read-path filter + a refresh job |
| Recurring cost | One-off generation | Ongoing PAYG search + weekly regeneration |
| Risk | Low — fits #72's "dormant toggle" model | Higher — touches the live read path + a scheduler |
| Effort | Small (prompt + topic-pool entries) | A genuine mini-project |

**Recommendation: ship evergreen first (F-3a), do current/viral as a separate founder-gated phase (F-3b).** Same end goal you picked ("oboje"), just sequenced — because current/viral is a different, heavier pipeline that adds recurring cost and a scheduler, and is **unsafe to ship without expiry wiring** (a "this week's #1" question would be served months later, silently wrong). This is the §6 decision.

---

## 2. Verified internal findings (first-hand spot-checked)

### What commit `91de085` removed (the "deleted news/CZ-SK sources")
- **`app/sourcing/news_source.py`** — sourced current events from free RSS (BBC + Reuters via rss-bridge), parsed by regex, stamped each fact with `expires_at = now + 30 days` and tags `["news","current-events"]`. **It was the *only* code that ever set an expiry on a fact, and the only current-events sourcing in the pipeline.** Removed because "RSS too brittle, deferred indefinitely."
- **`app/sourcing/czech_slovak_source.py`** — SK/CZ Wikipedia "Did you know" wrapper; removed as pure redundancy (`WikipediaSource(languages=["sk","cs"])` covers it). *Not relevant to a global-scope F-3.*

→ For current/viral, the deleted news path is exactly what needs a (better) replacement. The good news: it doesn't need RSS — Tavily can do it (§4).

### Current sourcing — what's already there
- **Three live fact sources** orchestrated concurrently by `FactSourcer`: `WikipediaSource` (EN), `OpenTriviaDBSource` (free opentdb.com, rewrites Q+A → declarative facts), `WebSearchSource` (Tavily).
- **OpenTriviaDB already maps the entertainment categories** — Film(11), Music(12), Television(14), Entertainment(15), Celebrities(26). They activate automatically when a topic matches. *Evergreen entertainment is sourced for free, today.*
- **Tavily is plain web-search only** (`web_search_source.py:42-47` passes `query`/`max_results`/`include_answer`/`search_depth`) — **no recency parameters**. The SDK supports them; the code doesn't use them.
- **`topic_pool.json` (the F-1 curated no-category pool) has zero entertainment entries** — so the "surprise me" path never lands on pop-culture today.

### Generation — how a category is added
- `AdvancedQuestionGenerator` loads exactly three prompt templates: `v2_cot`, `v3_fact_first` (active), `open`. **The `question_generation_kids.md` and `question_generation_themed.md` files exist but are NOT wired into any running code** — there is no category→prompt dispatch. A real `entertainment` category needs a prompt file **and** the dispatch logic to select it.

### Expiry columns — dormant scaffolding
- `expires_at` + `freshness_tag` exist in the migration, ORM, and shared Pydantic model — but **nothing sets them during generation.** The only expiry *script* (`scripts/expire_questions.py`) is **dead code** (imports from the deleted `apps/question-generator`). So the *write* side has to be built.
  > **⚠️ CORRECTION (verified first-hand, #76 Phase 2, 2026-06-29):** the claim that "nothing reads them to filter the live pool" is **WRONG.** The live serving read-path **does** filter on expiry — `QuestionRetriever.get_next_question` drops expired candidates at `apps/quiz-agent/app/retrieval/question_retriever.py:118` (and `:128` fallback) via `Question.is_expired()`, which is a verified no-op while `expires_at` is NULL (`packages/shared/quiz_shared/models/question.py:227-228`). So F-3b only needs to **set** `expires_at` to *activate* an existing, correct filter — it does **not** build one. See issue #76 decisions 5–7.

---

## 3. Prior-art — how trivia products shape "entertainment"

- **OpenTriviaDB** (the most-cloned free source): Entertainment = Film, Music, TV, Video Games, Books, Theatre, Comics, Anime, Cartoons. **100% evergreen — deliberately no celebrity/viral/current subcategory** (they exclude anything that can go stale).
- **Trivia Crack / Kahoot**: mix evergreen + viral in one Entertainment bucket with weekly-refreshed micro-topics (Music, TV, Movies, Pop Culture, "current trends"). This is the commercial model for blending both.
- **Pub-quiz / Jeopardy**: decompose into Film, Music, TV, Celebrities, Awards, and a clearly date-stamped "News of the week" round.

**Recommended driving-safe taxonomy — 4 flat buckets:** **Film · Music & Artists · TV & Streaming · Viral/Trending.** Hold Awards/Celebrities as tags inside those until volume justifies a split. Driving-specific exclusions: no visual-recognition topics (comics/anime), no list answers ("name all five nominees") — answers must be 1–4 spoken words.

---

## 4. Sourcing current/viral — options (cost + licensing)

| Source | Gives | Cost | Licensing verdict |
|---|---|---|---|
| **Tavily `topic=news`** ✅ *recommended* | Trending entertainment facts via real-time news index | Already PAYG, **no new key** | Clean — aggregates public content |
| TMDB | Trending films/TV, cast metadata | Free key | ⛔ **ToS forbids LLM commercial pipelines + charging for apps using it** without a written agreement — avoid in generation |
| MusicBrainz | Evergreen artist/release metadata | Free | ✅ Clean (ODbL, commercial OK + attribution) — but **no trending signal** |
| Last.fm | Real-time music charts | Free key | ⚠️ Commercial use needs written permission |
| NewsAPI.org | Entertainment headlines | **$449/mo** for production | ⛔ Not viable |
| GNews | Entertainment headlines | Free 100/day | ✅ Commercial OK — viable *supplemental* offline source |

**The cheapest path is also the cleanest:** add recency params to the existing Tavily call — no new key, no license risk. Exact verified params (Tavily Search API, fetched 2026-06-29):
- `topic`: `general` | `news` | `finance` — `news` routes to real-time sources
- `time_range`: `day` | `week` | `month` | `year`
- `start_date` / `end_date`: `YYYY-MM-DD` for award-season windows
- (no `days` integer param exists)

→ Recipe for current entertainment: `topic=news`, `time_range=week`, query like `"viral streaming show 2026"`.

**Avoid TMDB in the generation pipeline** (licensing). Route movie/TV currency through Tavily news instead. *(Rule #11 cost note: this keeps us on one paid search provider, no new bill.)*

## 5. Keeping current content from going stale
- **Absolute phrasing, enforced in the prompt:** forbid "current/latest/this year/recently"; require a year anchor in the question text ("In 2026, who won…"). LLMs are temporally blind — a relative-time question silently rots with no error.
- **Content-class TTL tiers:** `evergreen` (no expiry) · `semi-stable` (award winners, 1–2 yr) · `current` (viral, 7–30 days).
- **Weekly regeneration** for the `current` tier only; evergreen is generate-once.
- **Read-path filter:** the live quiz must exclude `expires_at`-past questions. **⚠️ CORRECTION (verified #76 Phase 2):** it *already does* — `question_retriever.py:118,128` filters via `Question.is_expired()` (NULL-safe). So this is **not** a thing to build; F-3b only has to start *writing* `expires_at`. The partial-ship risk is therefore *degraded freshness* (pool thins to evergreen if the refresh job lags), **not** stale answers leaking. Shipping current/viral is consequently safer than this section originally implied.

---

## 6. Recommended build — phased, founder-gated

### F-3a · Evergreen entertainment — *small, low-risk, ships now*
1. New `prompts/question_generation_entertainment.md` — pop-culture tone, driving-safe answer rules (1–4 words, no visual/list answers), absolute phrasing.
2. Wire category dispatch in `AdvancedQuestionGenerator` so `category == "entertainment"` selects that prompt.
3. Add ~10 entertainment topics to `topic_pool.json` (Film/Music/TV/famous-people, no viral) so the no-category path can surface them.
4. Tests + a small validation batch. OpenTriviaDB/Wikipedia/Tavily already source it — **no new infra.**

Fits #72's reversibility model (commits-only, behind the existing category seam). This is the fast win.

### F-3b · Current/viral entertainment — *separate phase, recurring cost*
1. Recency-aware Tavily (`topic=news` + `time_range`) behind a flag / `NewsWebSearchSource`.
2. Populate `expires_at` + `freshness_tag` at generation (by content-class), **and** add the `expires_at` read-path filter (so stale questions are never served).
3. A scheduled refresh/regenerate job for the `current` tier (replaces the dead `expire_questions.py`).
4. Absolute-phrasing prompt constraints + a `content_class` tag.

This adds a scheduler, read-path changes, and ongoing PAYG + regeneration cost — a real mini-project, and **unsafe to ship partially** (no expiry filter = stale questions leak).

### The founder decisions (§1 + these)
1. **Phase it (recommended) or both-at-once?** I recommend F-3a now, F-3b as a separate go.
2. **Taxonomy:** OK to start with the 4 flat buckets (Film · Music & Artists · TV & Streaming · Viral/Trending)?
3. **Un-park coupling:** F-3a can be built dormant like the rest of #72, but it only produces value once generation is un-parked. Build now (dormant) or hold until un-park?

---

## Sources
OpenTriviaDB · Trivia Crack · Sporcle · Kahoot taxonomies · [Tavily Search API](https://docs.tavily.com/documentation/api-reference/endpoint/search) · [TMDB ToS](https://www.themoviedb.org/api-terms-of-use) · MusicBrainz (ODbL) · Last.fm API · NewsAPI/GNews pricing · ["Temporally Blind LLM Agents" arXiv 2510.23853](https://arxiv.org/html/2510.23853v2). Internal refs first-hand verified: `91de085`, `web_search_source.py:42-47`, `advanced_generator.py:163-204`, `opentriviadb_source.py` CATEGORY_MAP, `topic_pool.json`, expiry columns dormant.
