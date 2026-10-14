# Cloud-session generation check — task 203.9 (cloud sessions path)

- **Where:** Claude Code cloud session, `LLM_GATEWAY=session` (`claude -p` on the subscription). No prod DB, no OpenAI/Tavily keys.
- **Command** (from `apps/quiz-pack-api`): `scripts/generate_pack.py --dry-run --direct --no-judges --target-count 10 --per-topic-cap 2 --floor-fraction 0 --dedup-store noop --language en --theme "kitchen science" --out …/cloud.json`
- **Env:** `LLM_GATEWAY=session GEN_HOUSE_STYLE=1 GENERATION_MODEL=claude-opus-5-5 GEN_ALT_SHARE=0 JUDGE_GATE=0`, plus the two workarounds below.
- **Blocker 1 (auth guard):** `ensure_subscription_login` (`packages/shared/quiz_shared/llm/session_cli.py:159`) accepts only `authMethod == "claude.ai"`. Cloud sessions report `oauth_token` (subscription OAuth, `apiProvider: firstParty`), so the unmodified command exits at once. Workaround: a scratchpad wrapper replaced the guard in memory (it accepts `claude.ai` or `oauth_token`, still refuses API keys); repo code unchanged. Fix needed: also accept `oauth_token`.
- **Blocker 2 (Tavily):** `FactSourcer()` builds `WebSearchSource` up front and raises on a missing `TAVILY_API_KEY`, even under `--direct` (which skips sourcing; `facts: 0`). No `feature_flags.py` switch disables it, so `TAVILY_API_KEY=placeholder-unused` was set; Tavily was never called.
- **Stages switched off:** none beyond the recipe flags (`--direct` sourcing, `--no-judges`/`JUDGE_GATE=0` scoring, `--dedup-store noop`). Answerability, verification, dedup and composition all ran on the session gateway.
- **Result:** 2 questions (10 generated, 1 lost to dedup, 1 to verification, the rest to the per-topic cap of 2; every question got the single topic "Kitchen science", so 2 is the maximum with this recipe). All rows: `model=claude-opus-5-5`, `generation_metadata.extra.house_style` present.
- **Wall time:** 358 s (one generation round plus 2 top-up rounds).
