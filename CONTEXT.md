# Context

The shared domain language used in this codebase, in PRDs, in issue files, and in conversations with Claude. Use these terms exactly. Don't drift into synonyms — when a synonym sneaks into a PR or doc, rename it back to the canonical term.

This file is consulted by `/to-prd`, `/zoom-out`, `/diagnose`, `/improve-codebase-architecture`, and `/triage` — keep it accurate or those skills drift with it.

## Product

**Hangs**
Current product name. The iOS app and the App Store / TestFlight identity. Renamed from CarQuiz on 2026-04-19.
_Avoid_: CarQuiz (legacy), the app, our trivia app.

**CarQuiz**
Legacy product name. Still appears in: Sentry org/project slug (`missinghue/carquiz`) and StoreKit product IDs. Do **not** rename either of those — they are stable identifiers. Everywhere else, use Hangs.

**quiz-agent**
The monorepo and the FastAPI backend service inside it. Always lowercase, hyphenated. Backend deploys to `quiz-agent-api.fly.dev`.

**Voice-first quiz**
The core experience: TTS reads the question, the user answers by speaking, evaluation happens server-side, the result is read back. Designed for hands-free use while driving.

## Quiz mechanics

**Quiz session**
A single play-through containing N questions. Server-side state in memory; not persisted across restarts.

**Question**
A unit of content with prompt, expected answer, optional images/sources, difficulty, category, language. Backend Pydantic model in `packages/shared/`.

**Participant**
A player in a quiz session. MVP is single-participant. Multiplayer is post-MVP (see `.out-of-scope/multiplayer-mvp.md` if rejected as enhancement).

**QuizState**
The iOS state machine driving QuestionView. Transitions are gated by `validTransitions`. The probe `accessibilityIdentifier == "question.state"` exposes current state for UI tests.
_Avoid_: app state (too generic — that's `AppState`).

**Streaming STT**
Real-time speech-to-text via SpeechAnalyzer + SpeechTranscriber (iOS 26+). Default voice path. The user's device runs iOS 26+; SpeechAnalyzer is always active.

**Whisper STT**
OpenAI Whisper as a fallback / Slovak-quality path. Round-trip via the backend.

**Confirmation sheet**
The `AnswerConfirmationView` that appears after the user finishes speaking. Lets the user edit the transcript, re-record, or confirm.

**Auto-confirm**
A timer that fires `confirmAnswer()` ~10s after the confirmation sheet appears with an unedited transcript. Currently routes through `resubmitAnswer` for streaming-STT paths — that's issue 19.

**Barge-in**
Interrupting the question being read aloud to start answering early.

**Repeat / Mute / Skip**
Voice commands always available. "Repeat" replays the question; "Mute" silences TTS; "Skip" advances without scoring.

## Question pipeline

**gen-verify-score pipeline**
The three-stage content pipeline:
1. **Generate** (`/gen-questions`) — Claude produces candidate questions.
2. **Verify** (`/verify-qs`) — fact-check against sources, populate `source_url` + `source_excerpt`.
3. **Score** (`/score-qs`) — rate on 5 quality dimensions, recommend approve / revise / reject.

The full pipeline is operational for **Group A**. **Groups B-E** are the remaining content tranches.

**Question group**
A tranche of questions generated together with a shared topic / difficulty profile. A, B, C, D, E.

**5 quality dimensions**
The scoring axes used by `/score-qs`. (Domain-internal; see the skill for definitions.)

**ChromaDB**
Vector store for question semantic search. Production volume mount: `/app/data/chroma`. The `CHROMA_PATH` Fly secret must match the mount.

**SQLite ratings**
Persistent question ratings store, separate from ChromaDB.

## Testing

**Regression scenarios (RS-NN)**
End-to-end UI scenarios in `docs/testing/regression-scenarios.md`. Each is a state-machine assertion: drive UI via XcodeBuildMCP + curl HTTP listener, assert state transitions, write per-run report. RS-01..RS-NN. Run via `/regression`.

**Per-run report**
Output of `/regression`, saved to `docs/testing/runs/<RS-id>-<date>.md`. Always ends with `VERDICT: PASS|FAIL`.

**HTTP listener / UI-test mode**
DEBUG-Local-only HTTP server bound to `127.0.0.1:9999` inside the iOS app. Lets the test runner inject mock STT events via curl. Replaces the broken `hangs-test://` URL scheme on iOS 26.3 sim.

**`--ui-test` flag**
Launch argument that puts the app into UI-test mode (mock services wired, HTTP listener active, mock data loaded).

**Pre-push smoke**
Lite RS-01 variant at `scripts/pre-push-rs01-smoke.sh`. Opt-in git hook installed via `scripts/install-pre-push-hook.sh`. Catches the failure mode where the HTTP listener stops binding.

**iOS schemes**
- `Hangs-Local` — points at `http://localhost:8002`
- `Hangs-Prod` — points at `https://quiz-agent-api.fly.dev`

**Question state probe**
`Text("...")` view with `accessibilityIdentifier("question.state")` exposing `QuizState` for UI test assertions. Pair with the status-pill fallback `question.statusPill` (AXValue) when the confirmation sheet overlays QuestionView.

## Process

**TODO**
`docs/todo/TODO.md`. Active work queue. States: `[ ]` todo · `[~]` wip · `[x]` done. Numbers continue the issue series.

**Issue file**
`docs/issues/issue-NN-{slug}.md`. Plan + history for sizable tasks. Header carries `**Triage:**` (machine-readable category + state) and `**Status:**` (human prose).

**PRD**
Product requirement doc in `docs/product/prds/<slug>.md`. Created via `/to-prd` (synthesize current conversation) or `/write-prd` (interactive interview).

**Indices**
`docs/issues/INDEX.md` and `docs/product/INDEX.md` are dashboards. Updated by `/triage` and `/to-prd`.

**ADR**
Architecture decision record in `docs/adr/NNNN-<slug>.md`. Created lazily by `/improve-codebase-architecture` when an architectural decision needs to be recorded so it isn't re-litigated.

**Wave 1/2/3 (crash elimination)**
Phases of crash work tracked under `project_crash_elimination` memory. Wave 1 + Wave 2 done; timer bug (open since 2026-04-15) is part of Wave 3.

**Fáza 5/6**
Slovak for "phase." Refers to the planned phases 5 and 6 of crash elimination work.

**ultrareview**
User-triggered multi-agent cloud review of the current branch (`/ultrareview`). User can launch; Claude cannot.

## Architecture vocabulary

For any architecture conversation, use the deepening vocabulary in `.claude/skills/improve-codebase-architecture/LANGUAGE.md`: **module**, **interface**, **implementation**, **depth**, **seam**, **adapter**, **leverage**, **locality**.

## Flagged ambiguities

- "CarQuiz" is still the legal identity in Sentry slug + StoreKit IDs. Renaming those would break alert routing and break in-flight purchases. Resolution: those two stay; everything else is Hangs.
- "Issue tracker" in mattpocock-skills documentation refers to GitHub Issues. **This repo has no GitHub Issues.** State lives in `docs/issues/issue-NN-*.md` files (`**Triage:**` line) and `docs/todo/TODO.md`. The `/triage` skill is adapted for that.
- "AppState" vs "QuizState" — `AppState` is the iOS app-level singleton; `QuizState` is the per-question UI state machine. Don't conflate.
