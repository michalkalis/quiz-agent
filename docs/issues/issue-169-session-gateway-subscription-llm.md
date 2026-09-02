# #169 — Session gateway: dev pipeline na Claude Code subscription

**Triage:** backend/content · in-review (PR)
**Status:** T1–T6 DONE 2026-09-02; PR open, čaká na nezávislý review
**Created:** 2026-09-02
**Reversibility:** `a` — additívne; `LLM_GATEWAY` unset/`direct`/`openrouter` = nezmenené správanie. Nikdy nenasadené na Fly (dev-only prepínač).

## Why

Founder (2026-09-02): dočasne presunúť čo najviac vývojovej práce s LLM (generovanie otázok, fact-check, eval harnessy, prekladový arm test z #168 — batch predprekladová pipeline SK/CS) z platených API na Claude Code subscription, ktorú už platí a nevie minúť. Podmienky: **backend API pipeline je vždy zdroj pravdy**, subscription cesta ju kopíruje 1:1 a nič nevymýšľa navyše (sudcovia ostávajú vypnutí tak, ako sú v prode); obe cesty sa musia udržiavať súčasne; embeddings a generovanie obrázkov ostávajú na API; ne-Claude modely nahradiť Claude modelmi, čo najlacnejšie.

Politika overená 2026-09-02 (code.claude.com/docs/en/headless, /authentication, /errors): `claude -p` na subscription je oficiálne podporovaný pre vlastné skripty (`claude setup-token` existuje presne na to); ráta sa do session/týždenných limitov subscription. Zakázané je len ponúkať subscription login v produktoch tretích strán cez Agent SDK — netýka sa nás.

## Locked decisions (founder 2026-09-02)

1. Jeden prepínač pre celú pipeline aj eval skripty, nie ručne opísané markdown skilly (dnešný `generate-questions-session` skill = parity fork, drift už nastal v `score-questions`).
2. Session režim mení **len transport** k modelu. Feature flagy, prompty, parsery, guardy, import — spoločný kód, nedotknutý.
3. Sudcovský panel/kritika/gate v2 zostávajú OFF (prod default). Session nič nezapína.
4. Mimo subscription: embeddings (OpenAI, centy), generovanie obrázkov, serve-time hot path v `apps/quiz-agent` (nikdy nebeží v session režime).
5. Ne-Claude modely sa v session režime mapujú na Claude tier podľa triedy (tabuľka nižšie); výsledky sudcov/arms v session režime sú **session-only**, neporovnávajú sa s prod panelom.

## Design

**Prefix `session:<alias>`** (`fable|opus|sonnet|haiku`) ako sesterský mechanizmus k `bedrock:` v `packages/shared/quiz_shared/llm/factory.py`:

- `LLM_GATEWAY=session` — tretia hodnota. `resolve_model()` mapuje každé chat model id na `session:<alias>`; `openai_client()` sa správa ako `direct` (embeddings/audio/image idú ďalej na OpenAI); embedding/audio/image id sa nikdy nemapujú.
- `chat_openai()` pre `session:` id vracia `ChatClaudeSession` (`quiz_shared/llm/session_cli.py`), LangChain `BaseChatModel`, ktorý spustí `claude -p` ako subproces. Podporuje presne to, čo call sites používajú: `ainvoke(str | [HumanMessage])` → `AIMessage` s `content`, `usage_metadata`, `response_metadata`; `with_structured_output(model, method="function_calling", include_raw=True)` cez `bind_tools` → `--json-schema` → `tool_calls`.
- Headless flagy: `--output-format json --max-turns 1|2 --no-session-persistence --tools "" --setting-sources "" --strict-mcp-config --mcp-config '{"mcpServers":{}}'` (réžia ~6.5k vs ~39k tokenov/volanie bez nich, merané 2026-09-02). Prompt cez stdin. `CLAUDECODE` env odstránené (nested volanie zo session funguje, overené). Timeout = `GENERATION_TIMEOUT`. Súbežnosť: semafor `LLM_SESSION_CONCURRENCY` (default 4).
- Web-grounded fact-check: `FactVerifier` dostane tretiu vetvu `_call_session` (`--tools WebSearch,WebFetch --allowedTools ...`, `max_turns` 8), rovnaký prompt a parser ako OpenAI/Anthropic vetvy; `cost_cents = 0`.
- Arm test #168 — batch predprekladová pipeline SK/CS: `translate_arms_backends.py` dostane transport `session` (Opus arm cez subscription); batch/sync/deepl nezmenené.
- Usage: tokeny sa hlásia do `llm_usage` (model `session:<alias>` = unpriced → cost 0 / `unpriced_models`), aby sa spotreba dala vidieť.

### Mapovanie id → session alias (`LLM_GATEWAY=session`)

| Prod id | Alias | Prečo |
|---|---|---|
| claude-fable-5 | fable | parita s GEN |
| claude-opus-5 / claude-sonnet-5 / claude-haiku-* | opus / sonnet / haiku | 1:1 |
| gpt-5.6-sol, gemini-3.1-pro-preview, deepseek-v4-pro, gpt-4.1, gemini-2.5-pro | opus | frontier trieda (critique/judge/normalize/verify — väčšina OFF v prode) |
| gpt-5-mini (FACTCHECK) | sonnet | web fact-check presnosť; haiku = kandidát po validácii na 7-chybovej referencii z #166 — fact-check provider swap |
| deepseek-v4-flash (ANSWERABILITY) | haiku | flash-trieda je zámer (#135 — gen pipeline founder feedback round 2, D10) |
| bedrock:* a neznáme | opus | + warning log |

Override: `LLM_SESSION_MAP="gpt-5-mini=haiku,..."`. Per-role env (`LLM_ROLE_*`) funguje aj so `session:` id.

### Mimo scope / follow-up

- Sourcing (`openai_web_search_source`, `topic_planner`) — v prod defaulte (direct gen) sa nespúšťa; session vetva až keď pilot #167 — entertainment otázky z nedávneho diania dostane GO.
- `score-questions` skill drift (staré 5 dimenzií) — samostatná oprava alebo zrušenie.
- Batch API (#168 — batch predprekladová pipeline SK/CS, LD1) sa v session režime nepoužíva (sync `claude -p`).

## Tasks

- [x] T1 `session_cli.py` adaptér + factory hooky (`gateway`, `is_session_model`, `resolve_model`, `chat_openai`, `provider_for_model`, `supports_sampling_params`)
- [x] T2 testy: fake `claude` binárka na PATH (flagy, stdin prompt, JSON parse, structured output → tool_calls, chybové stavy), `resolve_model` mapovanie v session gateway, passthrough embeddings
- [x] T3 `FactVerifier._call_session` + preflight bez API kľúča v session režime + test
- [x] T4 `translate_arms_backends.py` transport `session` + test
- [x] T5 `/generate-questions --session` (skill nastaví `LLM_GATEWAY=session`, preflight `claude auth status`); zrušiť `generate-questions-session` skill; README/backend rules jedna sekcia
- [x] T6 smoke: 3 otázky dry-run cez session, porovnať funnel s API behom; TODO + memory

## Smoke 2026-09-02 (T6)

`LLM_GATEWAY=session python scripts/generate_pack.py --dry-run --target-count 3` (direct gen, default CLI flags): 3/3 vygenerované → dedup 3 → fact-check 3/3 verified (session:sonnet + WebSearch) → scoring → 3 finálne; `cost_cents: 0`, žiadny API kľúč okrem `OPENAI_API_KEY` (nepoužitý, dedup noop). Tokeny: gen 1 volanie (17.7k in / 3.7k out, fable) · fact-check 3 volania (59k in) · **scoring 42 volaní (168k in, opus)**.

**Zistenia:**
- `generate_pack.py` má sudcov (ScoringStage) **zapnutých by default** (`--no-judges` ich vypne; runbook #167 — entertainment otázky ho používa). Prod worker beží s `judge_gate` OFF. V session režime je to 80 % spotreby kvóty (opus). → founder call: má skill `--session` pridávať `--no-judges` (parita s prod workerom, šetrí kvótu), alebo držať CLI default (parita s API CLI behom)?
- `(no source)` pri všetkých 3 otázkach = vlastnosť direct-gen cesty (zdroje plní len sourcing stage v grounded režime), nie session.
- `LLM_SESSION_CONCURRENCY` default 4 < `VERIFIER_MAX_CONCURRENT` 8 → fact-check v session režime beží pomalšie (zámer: kvóta + lokálne subprocesy).
- Anthropic vetva má `_MAX_WEB_SEARCHES=5`; session vetva ohraničuje `max_turns=8` (nie počet searchov) — bez nákladového dopadu na subscription.
- Line caps prekročené: `factory.py` 568 (bolo 468), `fact_verifier.py` 444, `translate_arms_backends.py` 341 — kandidáti na split v samostatnom refactore (#152 — arch review small findings collector).

## Verification

- `cd packages/shared && pytest tests/ -v`, `cd apps/quiz-pack-api && pytest tests/ -v` zelené.
- `LLM_GATEWAY=session python scripts/generate_pack.py --dry-run --target-count 3` prejde generovanie → answerability → fact-check → guardy bez API kľúčov okrem `OPENAI_API_KEY` pre embeddings.
- Bez `LLM_GATEWAY` nezmenené správanie (existujúce testy).
