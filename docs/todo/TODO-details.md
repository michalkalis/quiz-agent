# TODO — migrovaný detail otvorených položiek

Tento súbor drží **verbatim** pôvodné (dlhé) znenie otvorených `- [ ]` / `- [~]` položiek z `docs/todo/TODO.md`,
ktoré pri zoštíhlení TODO.md 2026-08-26 nemali vlastný `docs/issues/issue-NN-*.md` súbor, kam by detail patril.
V TODO.md z nich ostal jednoriadkový záznam s odkazom `— [detail](TODO-details.md)`.
Položky, ktoré vlastný issue súbor majú, sú migrované tam (sekcia `## TODO detail (migrované z TODO.md 2026-08-26)`);
hotové položky sú v `docs/archive/todo/TODO-done-archive-2026-08-26.md`.

---

### ★ TOP PRIORITA — Entertainment otázky z nedávneho diania (web-search sourcing)

- [ ] **★ TOP PRIORITA (founder, 2026-08-12): Entertainment otázky z nedávneho diania — web-search sourcing.** Nová trieda otázok zo zábavného priemyslu viazaná na udalosti nedávnej doby, ktoré sú za knowledge cutoffom gen modelov → sourcing pre ne musí vyhľadávať aktuálne informácie na nete (web search; Tavily je zavedený provider). Founder príklad typu, ktorý ho zaujíma: známi hudobní producenti a akých umelcov majú pod sebou. Potrebuje vlastný design/prep round (napojenie na sourcing v gen pipeline, kontext #153 — generation pipeline mega review).

### Research: audio otázky — prehrávanie zvukových ukážok v kvíze

- [ ] **Research: audio otázky — znova preveriť možnosti prehrávania zvukových ukážok v kvíze (founder, 2026-08-19).** Audio sa do voice-first kvízu brutálne hodí → zistiť, čo sa reálne dá prehrávať v rámci otázok. Preveriť per kategória: (1) úryvky pesničiek — právna stránka (rozšírená predstava „pár sekúnd je OK" vs. realita; licencované preview zdroje, napr. oficiálne 30s preview API), (2) úryvky/rozhovory z filmov a seriálov, (3) voľne použiteľné zvuky — zvieratá, prostredie, efekty (public domain / CC knižnice) a ďalšie typy. Nezužovať na existujúce otázky — preskúmať celý priestor audio-otázok. Výstup = research doc v `docs/research/` s právnym posúdením a použiteľnými zdrojmi/API per kategória + odporúčanie, čo z toho vieme nasadiť.

### Entertainment otázky z aktuálneho diania

- [ ] **Entertainment otázky z aktuálneho diania (founder, ~2026-08-12, celkovo prioritné)** — otázky o veciach, čo sa udiali v nedávnej dobe; informácie sa budú vyhľadávať na nete. Príklad žiadaného typu otázok (nie nutne aktuálneho): známi hudobní producenti a ktorých umelcov majú pod sebou. Pozn.: news-sourcing + expiry infra na toto už existuje dormantná z #76 — `entertainment` kategória F-3b (`ENABLE_NEWS_SOURCING` + `EXPIRY_CLASSIFICATION`, oba default off). Zapracovať cez gen-pipeline review plán — kandidát 17 v `docs/research/gen-pipeline-joint-review-2026-08-09.md` (experimentálne kolo D21 + entertainment prompt).

### Blind test lacnejších gen modelov vs Fable 5 (po D21b)

- [ ] **Blind test lacnejších gen modelov vs Fable 5 (po D21b)** — 3-ramenný blind test na ďalšom ratingovom kole: **Fable 5 (Batch, baseline) vs Opus 5 (Batch, $2.50/$12.50 = ~25 % ceny Fable) vs Kimi K3 ($3/$15, #2 creative writing, vyžaduje OpenRouter top-up)**. Cieľ: zraziť COGS custom packov na ~30–50 % pri udržaní kvality; gen model sa mení len s eval dátami + founder approval. DeepSeek V4 do gen fázy NEzaraďovať (halucinácie 94–96 % na AA-Omniscience; v critique/verify roli V3.2 ostáva OK). GLM-5.2 ($1.40/$4.40) len ako prípadné 4. rameno — chýbajú dáta o fakticite. Research: [llm-models-question-generation-2026-08](../research/llm-models-question-generation-2026-08.md). Pôvodné zadanie: väčšia kvalitná sada (Fable 5 direct v1 + e-news reprompt s konkrétnymi faktami/menami vrát. founderovho príkladu s producentmi), hodnotenie na DVOCH osiach (michal 1–10 = produkt; druhý rater editorský checklist, nie škálu), dedupe pred publikáciou; cieľ = re-validácia critique/judges/verify na kvalitných otázkach + rozšírenie eval setu #165. Prod prepnutie gen modelu až po D21b. Metodika zafixovaná v issue-164 § Metodika ďalšieho kola.

### Pre-App-Store removal: in-app rating affordance (#155, D24)

- [ ] Pre-App-Store removal: in-app rating affordance (#155, D24) — runtime TF gating ju v App Store buildoch skryje, ale pred GA odstrániť aj kód (spolu s TEMP `generatedBy` badge riadkom nižšie). Mechanika odstránenia: zmazať `.questionRatingEntry(…)` v `QuestionView.swift` + `ResultView.swift`, `ratingEntry` parametre a `ContentView.ratingEntry`, potom celý adresár `Hangs/Views/Rating/` + `QuestionRatingService`/`MockQuestionRatingService`/`Models/QuestionRating.swift`/`Utilities/BuildChannel.swift` a testy `QuestionRating*Tests.swift`.

### Apple root cert (AppleRootCA-G3.cer) nie je v gite

- [ ] Apple root cert (`AppleRootCA-G3.cer`) nie je v gite — deploy z čerstvého worktree/checkoutu bez ručne stiahnutého certu nasadí rozbitý StoreKit (stalo sa 2026-08-06, retry endpoint 500). Fix: commitnúť cert do repa (je verejný) alebo sťahovať v Dockerfile s checksumom

### Remove TEMP `generatedBy` provenance badge

- [ ] Remove TEMP `generatedBy` provenance badge from `QuestionView.swift` (both MCQ + voice bodies + helper, grep `TEMP (Bedrock gen test)`) before any App Store release build — added 2026-08-01 for the founder's Bedrock generation field test (shows `generation_metadata.model` under the question text).

### [HUMAN] #140 — Pack purchase on real StoreKit, founder leg 2 (sandbox e2e)

- [ ] `[HUMAN]` #140 founder leg 2 (after leg 1): request a TF build → sandbox e2e on device (order → Apple charge sheet → generation → play; admin-key field must be absent). Pre-GA reminder lives in the issue: flip `STOREKIT_ENVIRONMENT` Sandbox→Production.

### Učiaca sa gen pipeline (founder wish 2026-08-03)

- [ ] **Učiaca sa gen pipeline (founder wish 2026-08-03, budúci issue)** — keď je otázka hodnotená dobre (founderom alebo hráčmi v appke), review proces má reverzne zistiť PREČO funguje a poznatok vrátiť do pipeline (gold pool, critique kotvy, váhy vzorov); to isté pre zle hodnotené. Zachytené v issue #135 § Future; potrebuje vlastný design round (zdroj dát = in-app ratingy + founder hodnotenia).

### Continue CI hygiene — 2 residual iOS flakes

- [~] Continue CI hygiene — 2 residual iOS flakes keep iOS CI red every run (ConfirmResultCommandTests = same `.serialized` fix; EntitlementReconcileTests = own backoff-timer root cause; + optional systemic disable-parallelism). See docs/handoffs/handoff-2026-07-22-1050.md. **Re-confirmed 2026-07-26 (run `30204737148` on `806a667`, red — iOS CI has been red on `main` every run since 2026-07-17):** the 4 failures are `EntitlementReconcileTests/{usageRecoversWithinRetries,retriesWithBackoff,usageFailureMarksFailedWhenNothingCached}` + `HomeFreePlanCardTests/failedUsageShowsRetryPlaceholder`, and **all 4 pass locally twice** (a 5th, `foregroundReconciles`, flaked once locally then passed) — so it is still the timing/global-hook fragility, not app breakage; `getUsageCallCount` stuck at 1 vs ≥3 is the shared signature. Root fix = inject the backoff clock instead of `waitUntil`-ing real sleeps (the tests wait on production `Task.sleep` backoffs with 15 s headroom, which CI load blows through).

### [HUMAN] Delete the old Upstash Redis database

- [ ] **[HUMAN] Delete the old Upstash Redis database** — from ~2026-07-21, once `quiz-pack-redis` has a few stable days (check: `fly logs -a quiz-pack-api` / `-staging` sweep cron green, no Redis errors). Founder deletes the DB in the Upstash web console (free tier, no cost — pure cleanup so nothing reconnects to it by mistake). Agent can walk through it on request.

### Optional cleanup: align staging DATABASE_URL host

- [ ] Optional cleanup: align staging `DATABASE_URL` host to `quiz-pack-db.internal` (prod shape) — staging works today via `flycast`+`sslmode=disable`, but two DSN shapes across envs invites the issue-60 TLS-reset gotcha again. One-liner + sweep-green verify; classifier-blocked for agents, so founder runs it (same pattern as the prod fix 2026-07-17).

### Post-answer context payoff — app/serving playback (#72 follow-up)

- [ ] Post-answer context payoff — app/serving playback (#72 follow-up, founder ask 2026-07-10): questions now carry a 1-2 sentence spoken context blurb in `explanation` (generation side done); the voice flow + iOS must read it aloud after the answer reveal. Scope: quiz-agent answer endpoint/TTS + iOS playback. Sequence with founder.
  - **✅ Phase 6b PASSED 2026-06-27 — founder approved quality** (`docs/artifacts/question-fun-phase6-validation-2026-06-27.html`). Still PARKED (un-park = separate founder go: scale + categories TBD). Shipped `79a68b1`: provenance records real model+provider+`generation_flow` tag, `odd_one_out` recipe hardened. **3 follow-ups queued (NOT started):** (1) no-category "LLM-picks-topics" grounded+sourced mode, (2) per-question `source_url` attribution fix (`generation.py:201-232` — whole pack currently cites one URL), (3) new `entertainment` category (celebrity/current/viral, low-knowledge — needs sourcing research). See `docs/handoffs/handoff-2026-06-27-2114.md`

### #74 — Best OpenRouter models for creative question generation

- [ ] #74 Best OpenRouter models for creative question generation — [research](../research/openrouter-creative-question-models-2026-06-26.md) — **founder-requested 2026-06-26** (recurring want). Generation runs through the OpenRouter gateway (#53), so pick the best / most-suitable model for *creative* question gen + the cheap critique/rewrite role (today `gpt-4o` gen / `gpt-4o-mini` critique). Feeds **#72 Phase 6 / Lever-A** — the dormant `GENERATION_MODEL` swap (`claude-opus-4-8` already in the OpenRouter slug remap). A background research subagent generated the linked report (creativity · instruction-following · structured output · Slovak/multilingual · OpenRouter $/M · latency). **Validate live before the paid Phase-6 flip.**

### (low) Make SilenceDetectionService timing tests deterministic

- [ ] (low) Make `SilenceDetectionService` timing tests deterministic — 10 of the 12 known iOS-CI fails are flaky wall-clock-timing asserts that flap under parallel suite load (not real bugs). Inject a fake clock / use expectations instead of real sleeps so CI can go green. The other 2 fails are stale `QuestionView` snapshots, already scheduled for re-record in 52.18 (after #56 SK copy settles). Keep all 12 tests — they're meaningful; this just removes the flakiness. Not urgent: only cost is red CI masking new regressions.

### Hetzner migration plan

- [ ] Hetzner migration plan — founder decision 2026-07-05: Hetzner VPS (+ Coolify/Compose) is the preferred hosting target short-to-mid term (flat €4–8/mo, no cold starts); Fly.io stays until migrated. Platform analysis: `docs/artifacts/flyio-fit-and-oom-fix-2026-07-05.html`. Next step: `/prepare-issue` for the migration (web+worker+pgvector Postgres+secrets+CI deploy path; keep Upstash or co-locate Redis)

### Review + merge mba-only #56 localization work

- [ ] Review + merge mba-only #56 localization work — 8 commits on `origin/ralph/overnight-20260613-1034` (Localizable.xcstrings, 56.1–56.5); likely resolves the "Slovak didn't activate" UI-review discrepancy. Also verify `ralph/overnight-20260622-2142` (#72 P0 flags) against reconciled #72 state. Found during founder review 2026-07-05 (`docs/reviews/founder-decisions-2026-07-05.md`)

### Founder-reported iOS bug/UX batch (2026-07-12)

- [~] Founder-reported iOS bug/UX batch (2026-07-12) — worked 2026-07-12 PM session:
  - [x] "Call Mode" toggle subtitle — pen `Jjcs5` arow3 + `HangsToggleRow` subtitle param; reuses the existing AudioMode description string ("Uses Bluetooth microphone (may show as phone call in car)") — **founder may still tweak wording**
  - [x] "Current language" → "Quiz language" (pen + `SettingsView`) — **founder may still tweak wording**
  - [x] Native back button + native swipe in Settings — deleted `HangsNavBar.swift` (`HangsBackChip` + `NavigationPopGestureEnabler`, the #80 custom gesture); pen back chip replaced with native-style back
  - [x] TTS Slovak numbers — root cause: translated text keeps digits, OpenAI tts-1 has no locale lever → deterministic digit→words normalization (`num2words` sk/cs) on the TTS input only (`app/tts/number_normalization.py`), display text unchanged; 9 unit tests
  - [ ] Voice commands "start"/"stop"/"skip" — diagnosed, NOT a code fix yet: commands are English-only by design, armed only in narrow windows (never during TTS playback or answer recording), and "stop" is only a confirmation/undo-skip word — founder usage note delivered in session report. Open follow-ups: 77.15 on-device accent gate still unrun; no Sentry mirroring of recognizer health; no visible "listening" indicator (77.12 CmdListenBar unshipped)
  - [x] Quiz top bar renders at launch — `.startingQuiz` now mounts QuestionView (ContentView routing) so chrome shows during load
  - [x] Bottom controls one horizontal row (THINK chip · type-answer link · mute) — `audioStrip(withTypeToggle:)` + pen f9csl/uGhZg/w8s5Mj
  - [x] Image question — NOT a bug: defaults are off end-to-end; the Home-screen "Image questions" toggle is sticky per device and is most likely ON on founder's phone (left from #68 testing) — founder to check
  - Pen changes (Settings + 3 question frames) still gated on founder ⌘S save in Pencil; bonus: fixed pre-existing red `muteTogglesSetting` test (async race since 8a01675)

