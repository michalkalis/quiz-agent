# #169 — Session gateway: dev pipeline na Claude Code subscription

**Triage:** backend/content · in-progress (agent)
**Status:** implementing
**Created:** 2026-09-02
**Reversibility:** `a` — additívne; `LLM_GATEWAY` unset/`direct`/`openrouter` = nezmenené správanie. Nikdy nenasadené na Fly (dev-only prepínač).

## Why

Founder (2026-09-02): dočasne presunúť čo najviac vývojovej práce s LLM (generovanie otázok, fact-check, eval harnessy, prekladový arm test) z platených API na Claude Code subscription, ktorú už platí a nevie minúť. Podmienky: **backend API pipeline je vždy zdroj pravdy**, subscription cesta ju kopíruje 1:1 a nič nevymýšľa navyše (sudcovia ostávajú vypnutí tak, ako sú v prode); obe cesty sa musia udržiavať súčasne; embeddings a generovanie obrázkov ostávajú na API; ne-Claude modely nahradiť Claude modelmi, čo najlacnejšie.

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
- #168 arm test: `translate_arms_backends.py` dostane transport `session` (Opus arm cez subscription); batch/sync/deepl nezmenené.
- Usage: tokeny sa hlásia do `llm_usage` (model `session:<alias>` = unpriced → cost 0 / `unpriced_models`), aby sa spotreba dala vidieť.

### Mapovanie id → session alias (`LLM_GATEWAY=session`)

| Prod id | Alias | Prečo |
|---|---|---|
| claude-fable-5 | fable | parita s GEN |
| claude-opus-5 / claude-sonnet-5 / claude-haiku-* | opus / sonnet / haiku | 1:1 |
| gpt-5.6-sol, gemini-3.1-pro-preview, deepseek-v4-pro, gpt-4.1, gemini-2.5-pro | opus | frontier trieda (critique/judge/normalize/verify — väčšina OFF v prode) |
| gpt-5-mini (FACTCHECK) | sonnet | web fact-check presnosť; haiku = kandidát po validácii na 7-chybovej referencii z #166 |
| deepseek-v4-flash (ANSWERABILITY) | haiku | flash-trieda je zámer (#135 D10) |
| bedrock:* a neznáme | opus | + warning log |

Override: `LLM_SESSION_MAP="gpt-5-mini=haiku,..."`. Per-role env (`LLM_ROLE_*`) funguje aj so `session:` id.

### Mimo scope / follow-up

- Sourcing (`openai_web_search_source`, `topic_planner`) — v prod defaulte (direct gen) sa nespúšťa; session vetva až keď #167 pilot dostane GO.
- `score-questions` skill drift (staré 5 dimenzií) — samostatná oprava alebo zrušenie.
- Batch API (#168 LD1) sa v session režime nepoužíva (sync `claude -p`).

## Tasks

- [x] T1 `session_cli.py` adaptér + factory hooky (`gateway`, `is_session_model`, `resolve_model`, `chat_openai`, `provider_for_model`, `supports_sampling_params`)
- [ ] T2 testy: fake `claude` binárka na PATH (flagy, stdin prompt, JSON parse, structured output → tool_calls, chybové stavy), `resolve_model` mapovanie v session gateway, passthrough embeddings
- [ ] T3 `FactVerifier._call_session` + preflight bez API kľúča v session režime + test
- [ ] T4 `translate_arms_backends.py` transport `session` + test
- [ ] T5 `/generate-questions --session` (skill nastaví `LLM_GATEWAY=session`, preflight `claude auth status`); zrušiť `generate-questions-session` skill; README/backend rules jedna sekcia
- [ ] T6 smoke: 3 otázky dry-run cez session, porovnať funnel s API behom; TODO + memory

## Verification

- `cd packages/shared && pytest tests/ -v`, `cd apps/quiz-pack-api && pytest tests/ -v` zelené.
- `LLM_GATEWAY=session python scripts/generate_pack.py --dry-run --target-count 3` prejde generovanie → answerability → fact-check → guardy bez API kľúčov okrem `OPENAI_API_KEY` pre embeddings.
- Bez `LLM_GATEWAY` nezmenené správanie (existujúce testy).
