# Issue #77 — Execution plan + ready-to-paste session prompts

**Created:** 2026-07-03 (regenerated — the previous split assumed the superseded cycle-2 design: VAD auto-arm + Slovak ElevenLabs-transcript matching. This file is **fully regenerated** against the re-planned **native-English-command / button-START** design.) #77 is large (15 tasks across a backend guard + an iOS audio/recognizer stack + a Pencil design pass) — so it's split into session-sized, independently-committable chunks. Each chunk below has a self-contained prompt: open a fresh session, paste the fenced block, go.

> Parent plan: [`issue-77-voice-commands-handsfree.md`](issue-77-voice-commands-handsfree.md). Research: [`../research/voice-commands-handsfree-research-2026-07-02.md`](../research/voice-commands-handsfree-research-2026-07-02.md) + delta [`../research/voice-commands-native-english-delta-2026-07-03.md`](../research/voice-commands-native-english-delta-2026-07-03.md).

**Class `a`** (pure iOS feature + one small backend guard; no auth / payments / DB schema / migrations). Both Phase-5 gates green: `/ready-check` **READY** (0 blockers) · `/design-soundness` **SOUND 0.84**. → **`ready-for-agent`**. The only non-agent piece is the final **77.15 `[HUMAN]` on-device gate** (Session 8), which is explicit and non-blocking for the agent sessions.

---

## Recon snapshot — what the codebase already gives us

*(Lifted from the issue's re-verified line anchors — HEAD-checked 2026-07-03. Minor drift is noted inline; re-grep the symbol if a line number is off by a few.)*

**Backend (`apps/quiz-agent`):**

- **Ghost-question path** — `app/quiz/flow.py`. The intent loop is followed (~`:256-302`) by the session-advance block: `current_question_id` advance `:272-273`, `record_question()` `:277`. A non-answer intent (`result.evaluation is None`) currently falls through and silently advances the session + burns a freemium question (#66). Guard = early-return before the advance block.
- **Tests** in `apps/quiz-agent/tests/` — pytest, mock OpenAI, fixtures. New file `test_flow_intent_guard.py`. Run: `cd apps/quiz-agent && pytest tests/ -v`.

**iOS (`apps/ios-app`, Xcode project "Hangs"):**

- **`SilenceDetectionService.swift`** — iOS 26 `SpeechAnalyzer`/`SpeechDetector` used as **model-based VAD** (1.5 s hangover). It **already instantiates a paired `SpeechTranscriber`** (declared `:108`, comment block from `:106`) to satisfy the CARQUIZ-3 forced detector↔transcriber pairing — but that transcriber's `.results` stream is **never consumed** (only `detector.results` is read at `:195`). Its own engine `:125`, tap `:162`. **This unused transcriber, re-localed to English + a `.results` consumer loop, is the cheapest command-listener seam — no new engine, same tap.**
- **`AudioService.swift`** — ElevenLabs streaming path: engine block `~:605` (minor drift; grep `AVAudioEngine`), tap `:652`, `startStreamingRecording`, `stopStreamingRecording()` `:704`. `handleInterruption` `.began` (`:385-388`) calls the **batch** `stopRecording()` and never `stopStreamingRecording()` → stranded-recording-after-a-call bug (#67 Part A).
- **`QuizViewModel.swift`** — the `QuizState` machine (`idle→startingQuiz→askingQuestion→recording→processing→(skipping)→showingResult→finished`+`error`) with `validTransitions`. `startRecording()` path. **Dead `repeatQuestion()` at `:1017`** (currently unwired). `QuizViewModel+Audio.swift:95` — Engine A (VAD) re-armed after TTS, never torn down before Engine B (streaming) spins up → **two concurrent `AVAudioEngine`s** (the #64 crash config that 77.7 converges).
- **`ElevenLabsSTTService`** — owns **no audio hardware**; consumes PCM only via `sendAudioChunk`. The shared-tap fan-out feeds it; it must never spin its own engine.
- **`MCQTranscriptMatcher.swift`** (`Utilities/`) — the shipped fuzzy transcript matcher; the new `VoiceCommandMatcher` + `VoiceCommandLexicon` are its siblings and live next to it.
- **Doc-hygiene targets:** `CONTEXT.md:56` glossary ("voice commands always available"), `OnboardingView.swift:295` (`Say "skip", "pass", or "next" anytime`), `Logging.swift:32` (`Logger.voice` category comment).
- **Tests** — `HangsTests/`, **Swift Testing** (`import Testing`). `AVAudioSession` is **mocked** (the CI blind spot — real audio/BT regressions are invisible; the Apple recognizer `supportedLocales` is **empty on the Simulator**, so all headless suites **mock the recognizer**). Existing `HangsTests/AudioServiceTests.swift`.

**⚠️ Gotchas (design defensively):**
- SpeechAnalyzer has broken twice under iOS point releases — CARQUIZ-1 (Swift-6 tap `@Sendable`), CARQUIZ-3 (iOS 26.3 forced detector↔transcriber pairing) — plus the iOS 26.3 `start(inputSequence:)` long-lived-streaming regression. **The defensive degrade-to-buttons wrapper is mandatory, not optional.**
- **No `contextualStrings`/custom-vocabulary biasing** exists on the new `SpeechAnalyzer` framework (a real loss vs legacy `SFSpeechRecognizer`). Accent-robust word choice + fuzzy matching is the *entire* mitigation.
- The recognizer is **English regardless of app language** (the app is used/tested in Slovak). The answer path stays Slovak ElevenLabs; the command listener is a **separate** English recognizer, **time-disjoint** from the answer stream (button/timer START ⇒ no command listening during the answer window).

**Verification shorthand** — `xcodebuild test -only-testing:HangsTests/<Suite>` = `xcodebuild test -project apps/ios-app/Hangs/Hangs.xcodeproj -scheme Hangs -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HangsTests/<Suite>`. Backend: `cd apps/quiz-agent && pytest tests/ -v`. On-device-only checks carry `[HUMAN]`.

---

## Locked decisions (carry into every session)

Lift **verbatim by id** from the issue's `## Resolved design decisions`. Never re-derive.

| # | Decision | Provenance |
|---|---|---|
| **P1** | **No auto-mic START.** After the question TTS the app does **not** open the mic; the existing thinking-timer + mic-button flow is unchanged. Cycle-2 VAD auto-arm + pre-roll are dropped. | **Founder-locked 2026-07-03** |
| **P2** | **Voice commands = native-English on-device (`SpeechAnalyzer`), English-only for all users** — not ElevenLabs transcript matching. `DictationTranscriber` preferred for the tiny grammar, `SpeechTranscriber` fallback (A/B on device at 77.15). | **Founder-locked 2026-07-03** |
| **P3** | **Barge-in = OUT of scope.** Strict sequencing: TTS finishes → mic/command listener arms. No AEC / `.voiceChat` / `setPrefersEchoCancelledInput`. | **Founder-confirmed 2026-07-02** |
| **P4a** | **Spoken "start" opens the mic on `QuestionView`** (`askingQuestion`, after TTS) — the hands-free START recovery. **Coordinator-adopted; founder-overridable** to button-only START (override disables only this wiring, behind a flag default-ON, leaving the rest of the command layer intact). | **Coordinator-adopted 2026-07-03 (founder-overridable)** |
| **P4b** | **Command set = start · ok · next · repeat · skip** (+ optional "stop" to cancel). Screen-scoped; buttons + the 10 s auto-confirm stay as fallback. **Provisional — final word-set tuning happens at the 77.15 `[HUMAN]` accent gate; be prepared to swap words.** | **Coordinator-adopted 2026-07-03 (provisional; founder-overridable)** |
| **P5** | **GPT-style recording-UI polish = separate follow-up issue** (out of scope). The capture-phase observable is exposed so the follow-up binds without re-plumbing. | **Founder-delegated 2026-07-02** |
| **E-topology** | **One shared `AVAudioEngine` + one input tap** fanning PCM to (a) `SpeechDetector` VAD, (b) ElevenLabs `sendAudioChunk`, (c) the new English command transcriber. **Never two concurrent engines.** (b) and (c) are time-disjoint (button START). | Engineering (issue) |
| **E-match** | Fuzzy/phonetic + edit-distance matcher (sibling of `MCQTranscriptMatcher`), **screen-scoped**, confidence floor, diacritic/case fold, word-boundary tokenization + **per-token accent tolerance**. Skip = **strict whole-utterance** match + skip-confirm earcon + ~2.5 s undo window. | Engineering (issue) |
| **E-fallback** | Defensive wrapper: any transcriber/detector setup failure (CARQUIZ-3-class drift, 26.3 `start(inputSequence:)` regression, empty `supportedLocales`, <iOS 26) degrades to manual mic-button / tap control instead of crashing. **Mandatory.** | Engineering (issue) |
| **E-state** | One additive observable **capture-phase** (`idle → armed → listening → recording → processing`) on the view-model — source of truth for earcons + the deferred UI. **Do not** add `QuizState` cases / `validTransitions`. | Engineering (issue) |

**Dependencies (locked ordering):** #66 early-return guard (77.1) is a **HARD PREREQUISITE** — lands before the command layer. #67 Part A (77.2) lands **before or within** #77 and must not be regressed. (Both are their own change-set / commit scope: 77.1 under #66, 77.2 under #67.)

---

## Session breakdown

| Session | Tasks | Risk | Notes / dependency markers |
|---|---|---|---|
| **1 — Prerequisites** | 77.1 (#66 backend guard) + 77.2 (#67-A streaming teardown) | Low | Two independent bug-fix prerequisites (backend + iOS), carried **verbatim**. **Blocks** the command layer (#66 guard is the freemium backstop). Commit 77.1 under #66, 77.2 under #67. **⇄ parallelizable** with Session 6 (Pencil). |
| **2 — Pure-logic core** | 77.3 (lexicon + fuzzy matcher) + 77.4 (capture-phase observable) | Low | No audio, no recognizer — pure logic + unit tests. **Delivers symbols** Sessions 3–5 import. **⇄ parallelizable** with Session 1 and 6. |
| **3 — Audio topology** | 77.5 (windowed listener + defensive degrade) + 77.7 (single-engine convergence) + 77.6 (VAD-isolation check) | **High** | Highest-risk session. **77.7 folded in with 77.5 on purpose** (Gate-B caution 1: sequencing convergence *with* the listener re-plumb avoids doing the tap wiring twice). 77.6 verifies the English re-locale doesn't perturb the Slovak-answer VAD. **Depends on Session 2** (matcher + capture-phase). |
| **4 — Command wiring** | 77.8 (spoken "start" + override flag) + 77.9 (confirm/result/repeat windows) | Med | Wires recognized commands to actions per screen. **Depends on Sessions 2 + 3.** |
| **5 — Earcons + STOP tuning** | 77.10 (earcon set) + 77.11 (cabin-noise STOP constants) | Low | Language-neutral earcons off the capture-phase + STOP-on-silence tuning constants. **Depends on Sessions 2 (phase) + 3 (listener).** |
| **6 — Pencil design** | 77.12 (`design/quiz-agent.pen` via Pencil MCP **only**) | Low | Listening indicator + per-screen command hints + reworked onboarding explainer; every voice affordance keeps a visible button twin. **Pencil MCP tools only — never Read/Grep the `.pen`.** **⇄ fully parallelizable** (no code dependency). |
| **7 — Doc hygiene + headless harness** | 77.13 (doc/localization sweep) + 77.14 (headless verification harness, **gates the loop**) | Low | Final integration. 77.13 depends on 77.9 re-wiring `repeatQuestion()`. **77.14 depends on Sessions 2–5** (runs all command suites green + RS-05). ⚠️ **77.14's headless-suite line is contingent on 77.6 producing a real headless `VADIsolationTests`** — if 77.6 fell to the `[HUMAN]` fallback (detector path not headlessly exercisable), that isolation assertion is recorded in the 77.15 checklist instead, and 77.14 asserts only the suites that *are* headless. |
| **8 — `[HUMAN]` on-device gate** | 77.15 (accent · cabin noise · BT · interruption; final word-set tuning) | — | **Not agent-runnable.** On the iOS 26+ device: real `SpeechTranscriber`/`DictationTranscriber` A/B, Slovak-accented English routing, final word-set lock, cabin-noise STOP tuning, BT HFP/A2DP, phone-call interruption recovery. **Last, non-blocking for the agent sessions.** |

**Parallelism:** Sessions **1, 2, 6** can run concurrently (no shared files). **3 → 4 → (5, 7)** is the critical path; 3 depends on 2. **8** is last.

---

## Human prerequisites

Class `a` — no secrets / portal / migration steps gate the agent sessions. The **only** human step is **Session 8 (77.15)**: the founder runs the recorded on-device pass on their iOS 26+ device (speaking each command in their own Slovak-accented English, tuning STOP constants in real cabin noise, checking Bluetooth routing + post-call state). It gates *final acceptance*, not the agent sessions — Sessions 1–7 reach a machine-verified done-state without it.

---

## Ready prompt — Session 1 (Prerequisites: #66 guard + #67-A teardown)

```
Work on issue #77, Session 1 only: the two carried-verbatim prerequisites — 77.1 (#66 backend ghost-question guard) + 77.2 (#67 Part A streaming interruption teardown). Do NOT start any voice-command work — that's Sessions 2+. These are two independent bug-fixes; commit 77.1 under #66 and 77.2 under #67. Stop, commit, push when both are green.

Read first (don't re-map — this is known):
- docs/issues/issue-77-execution-prompts.md → "Recon snapshot" + "Locked decisions".
- apps/quiz-agent/app/quiz/flow.py → the intent loop (~:256-302), current_question_id advance (:272-273), record_question() (:277).
- apps/quiz-agent/tests/ → pytest patterns (mock OpenAI, fixtures).
- apps/ios-app/Hangs/Hangs/Services/AudioService.swift → handleInterruption .began (:385-388) calls batch stopRecording(); stopStreamingRecording() is at :704.
- apps/ios-app/Hangs/HangsTests/AudioServiceTests.swift → Swift Testing + AVAudioSession-mock patterns.

Build:
1) 77.1 (#66) — in app/quiz/flow.py, add `if result.evaluation is None: return result` after the intent loop and BEFORE the session-advance block (ahead of the current_question_id advance :272-273 and record_question() :277). The voice route must surface its 400 with NO state mutation; give the text /input path the same guard with a meaningful error. New test apps/quiz-agent/tests/test_flow_intent_guard.py: a non-answer intent leaves current_question_id unchanged, does NOT call record_question(), and surfaces the error. Commit under #66.
2) 77.2 (#67-A) — in AudioService.swift handleInterruption .began (:385-388): when audioEngine != nil, call stopStreamingRecording() (:704) AND notify QuizViewModel to leave .recording and reset streaming state. Extend HangsTests/AudioServiceTests.swift + a VM state assertion: a simulated interruption during streaming yields audioEngine == nil, isRecording == false, VM out of .recording. Commit under #67.

Done = `cd apps/quiz-agent && pytest tests/ -v` GREEN (incl. test_flow_intent_guard.py) AND `xcodebuild test -only-testing:HangsTests/AudioServiceTests` GREEN. Commit per fix, push to main. Tick 77.1 + 77.2 in issue-77-voice-commands-handsfree.md and update the docs/todo/TODO.md #77 line. Fail loud — no silent skips.
```

---

## Ready prompt — Session 2 (Pure-logic core: matcher + capture-phase)

```
Work on issue #77, Session 2 only: the pure-logic core — 77.3 (English command lexicon + fuzzy/phonetic matcher) + 77.4 (capture-phase observable). NO recognizer, NO audio, NO listener lifecycle — that's Session 3. Pure logic + unit tests only. Stop, commit, push when green.

Read first:
- docs/issues/issue-77-execution-prompts.md → "Recon snapshot" + "Locked decisions" (esp. E-match, E-state).
- apps/ios-app/Hangs/Hangs/Utilities/MCQTranscriptMatcher.swift → the sibling matcher style to mirror (fuzzy, diacritic/case fold).
- apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift → where the additive capture-phase @Published/@Observable goes; the QuizState machine + validTransitions (DO NOT add cases to these).
- apps/ios-app/Hangs/HangsTests/ → Swift Testing patterns.

Build:
1) 77.3 — new apps/ios-app/Hangs/Hangs/Utilities/VoiceCommandMatcher.swift + VoiceCommandLexicon.swift (constants sibling of MCQTranscriptMatcher). Lexicon = the accent-chosen English set start · ok · next · repeat · skip (+ optional stop/cancel), each with accent-tolerant variants. match(transcript:on screen:) tokenizes on word boundaries, folds diacritics/case, scores each token against ONLY that screen's 1-2 valid commands with phonetic/edit-distance distance + a confidence floor. Skip = STRICT whole-utterance match (transcript must BE the skip word modulo filler, not merely contain it). Expose a pure UndoWindow value type (~2.5 s) that a spoken cancel word ("stop"/"no") or a tap resolves to abort-vs-commit. No recognizer, no audio.
2) 77.4 — add ONE additive capture-phase (idle → armed → listening → recording → processing) to QuizViewModel as the single source of truth for earcons + the deferred UI. DO NOT add QuizState cases or validTransitions. Drive transitions off INJECTED lifecycle events (arm/listen/recognize/record/process).

Tests:
- HangsTests/VoiceCommandMatcherTests.swift over recorded/synthetic English transcripts: correct routing per screen; accented near-miss ("stat"→start) matches; non-command → no match; "ok"=confirm on the sheet vs =advance on the result (screen scoping); strict-skip REJECTS "let's skip this one" (contains-but-isn't skip); undo-window commit/abort timing.
- HangsTests/CommandCapturePhaseTests.swift: injected event sequence produces the expected phase sequence; illegal transitions are rejected/no-op.

Done = `xcodebuild test -only-testing:HangsTests/VoiceCommandMatcherTests` and `-only-testing:HangsTests/CommandCapturePhaseTests` both GREEN; a grep shows NO new QuizState cases / validTransitions. Commit (matcher+lexicon; capture-phase), push, tick 77.3 + 77.4.

Note for later sessions: you are DELIVERING the matcher entry point `match(transcript:on:)`, the lexicon constants, the `UndoWindow` type, and the capture-phase enum + its driver — Sessions 3/4/5 import these. Record their exact signatures under Status when done.
```

---

## Ready prompt — Session 3 (Audio topology: listener + single-engine + VAD isolation)

```
Work on issue #77, Session 3 only — the highest-risk session: 77.5 (windowed native-English command listener + defensive degrade-to-buttons) + 77.7 (single shared AVAudioEngine convergence) + 77.6 (VAD-isolation check). 77.7 is folded in with 77.5 deliberately so the tap is re-plumbed ONCE, not twice. Do NOT wire command→action routing (that's Session 4) or earcons (Session 5). Session 2 (matcher + capture-phase) must be merged first. Stop, commit, push when green.

Read first:
- docs/issues/issue-77-execution-prompts.md → "Recon snapshot" + "Locked decisions" (E-topology, E-fallback), and the ⚠️ gotchas (SpeechAnalyzer fragility, empty supportedLocales on Simulator, no contextualStrings).
- apps/ios-app/Hangs/Hangs/Services/SilenceDetectionService.swift → the paired-but-UNUSED SpeechTranscriber (declared :108, comment :106; only detector.results consumed at :195); engine :125, tap :162.
- apps/ios-app/Hangs/Hangs/Services/AudioService.swift → streaming engine block ~:605, tap :652, startStreamingRecording, stopStreamingRecording() :704.
- apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel+Audio.swift:95 → Engine A re-armed after TTS (the second concurrent engine to eliminate).
- Session 2's VoiceCommandMatcher + capture-phase (import their exact signatures from the Status notes).

Build:
1) 77.5 — re-locale the already-instantiated-but-unused paired SpeechTranscriber in SilenceDetectionService.swift to an ENGLISH locale and add ONE async consumer loop feeding Session 2's matcher — no new engine, same tap/buffers. Add a windowed listener lifecycle: armed ONLY on Home (idle) / Question (askingQuestion, after TTS) / Confirmation (processing) / Result (showingResult); TORN DOWN during TTS and re-armed after (the 1a19438 self-trigger guard, same rule as VAD); NEVER armed during recording. Wrap transcriber/detector setup + start(inputSequence:) in a DEFENSIVE guard: any throw/failure (CARQUIZ-3 drift, 26.3 streaming regression, empty supportedLocales, <iOS 26) degrades to the manual mic-button/tap flow instead of crashing. Recognizer MOCKED in tests.
2) 77.7 — converge onto ONE AVAudioEngine + one input tap fanning PCM to (a) SpeechDetector VAD (SilenceDetectionService engine :125 / tap :162), (b) ElevenLabs sendAudioChunk (AudioService streaming block ~:605 / tap :652), (c) the new command transcriber. startStreamingRecording must CONSUME the shared tap, never instantiate a second engine (ElevenLabsSTTService owns no audio hardware). (b) and (c) are time-disjoint (button START). Regression-guard the "no two concurrent engines" invariant.
3) 77.6 — verify the English re-locale does NOT change SpeechDetector VAD behaviour during the Slovak answer window: detector silence-hangover / stop-on-silence timing must be identical with the transcriber localed `en` vs its prior locale.

Tests (recognizer mocked throughout):
- HangsTests/CommandListenerTests.swift: listener armed/torn-down per state (assert against injected state changes); NO arming during TTS or recording; a thrown setup error leaves button-only mode, no crash, buttons functional.
- HangsTests/AudioServiceTests.swift (or new SharedEngineTests.swift): only ONE AVAudioEngine instance across a full ask→record→confirm cycle; command-listen and answer-stream are never both live.
- HangsTests/VADIsolationTests.swift: feed a fixed PCM/silence fixture through SilenceDetectionService; assert the detector.results stop-decision sequence + timing are byte-for-byte identical across the two transcriber-locale configs. IF the detector path cannot be exercised headlessly, DO NOT fake it: record an explicit written side-by-side detector-timing comparison step and fold it into the 77.15 [HUMAN] checklist, and note in your Status that VADIsolationTests fell to the [HUMAN] fallback (Session 7's 77.14 depends on knowing this).

Done = `xcodebuild test -only-testing:HangsTests/CommandListenerTests`, `-only-testing:HangsTests/AudioServiceTests` (single-engine + time-disjoint assertions), and `-only-testing:HangsTests/VADIsolationTests` all GREEN — OR VADIsolationTests explicitly deferred to 77.15 with the comparison step recorded. Commit per task, push, tick 77.5 + 77.6 + 77.7. Record under Status whether 77.6 is headless or [HUMAN]-deferred.
```

---

## Ready prompt — Session 4 (Command wiring: start / confirm / result / repeat)

```
Work on issue #77, Session 4 only: 77.8 (spoken "start" opens the mic on QuestionView, founder-overridable flag) + 77.9 (Confirmation-sheet + Result listening windows: "ok"/"again"/"next"/"repeat"). Sessions 2 (matcher/phase) + 3 (listener/engine) must be merged first. Do NOT touch earcons (Session 5) or VAD constants (Session 5). Stop, commit, push when green.

Read first:
- docs/issues/issue-77-execution-prompts.md → "Locked decisions" (P1, P4a, P4b).
- apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift → startRecording() path; the DEAD repeatQuestion() at :1017 (re-wire it); the QuizState machine.
- Session 3's windowed listener + Session 2's matcher (import exact signatures from Status).

Build:
1) 77.8 — wire the recognized "start" command on QuestionView (askingQuestion, after TTS) to the existing startRecording() path — the hands-free START recovery. Gate it behind a single build/settings flag (default ON) so the founder can override to button-only START, which disables ONLY this wiring and leaves the rest of the command layer intact (P4a). DO NOT add auto-mic-open — the thinking-timer + mic-button flow is unchanged (P1).
2) 77.9 — wire recognized commands on AnswerConfirmationView (processing): "ok" → confirm, "again"/"retry" → re-record, ON TOP OF the existing 10 s auto-confirm (unchanged, still the no-speech default) and the buttons; and ResultView (showingResult): "next"/"ok" → advance (auto-advance unchanged). Re-wire the dead repeatQuestion() (:1017) so "repeat" on QuestionView replays the question audio and re-arms the listener.

Tests:
- HangsTests/StartCommandTests.swift: flag ON → recognized "start" on askingQuestion invokes startRecording(); flag OFF → it does not; "start" is inert in every other state; no auto-mic-open path exists.
- HangsTests/ConfirmResultCommandTests.swift: "ok"/"again" route to confirm/re-record within the sheet window; the 10 s auto-confirm still fires with no speech; "next" advances on result; "repeat" invokes repeatQuestion() and re-arms.

Done = `xcodebuild test -only-testing:HangsTests/StartCommandTests` and `-only-testing:HangsTests/ConfirmResultCommandTests` GREEN. Commit per task, push, tick 77.8 + 77.9.
```

---

## Ready prompt — Session 5 (Earcons + cabin-noise STOP tuning)

```
Work on issue #77, Session 5 only: 77.10 (minimal language-neutral earcon set) + 77.11 (cabin-noise STOP tuning constants). Sessions 2 (capture-phase) + 3 (listener) must be merged first. Stop, commit, push when green.

Read first:
- docs/issues/issue-77-execution-prompts.md → "Locked decisions" (VAD parameter starting points; earcons language-neutral).
- Session 2's capture-phase enum + the matcher's recognize/skip events (import from Status).
- apps/ios-app/Hangs/Hangs/Services/SilenceDetectionService.swift → where SpeechDetector.sensitivityLevel + the silence hangover live; and the ElevenLabs streaming VAD params.

Build:
1) 77.10 — distinct tones for: mic-live (mic opens), got-it (STOP), skip-confirm (the 77.3 undo window), command-ack (a spoken command recognized). Driven off the 77.4 capture-phase + the matcher's recognize/skip events; NO words (language-neutral). Absorbs #68's record-start/stop earcon item (note in the commit that #68 should mark it delivered-by-#77). None emitted during TTS.
2) 77.11 — centralise STOP-on-silence tuning as NAMED constants: silence hangover ~1.2-1.8 s (keep near the current 1.5 s), a min-speech-duration to reject cough/blip false starts, SpeechDetector.sensitivityLevel .medium → .low for road noise, and ElevenLabs vadSilenceThresholdSecs / minSpeechDurationMs / minSilenceDurationMs. NO pre-roll/prefix-padding (START is button/timer, P1), no new VAD engine. Values are starting points to be finalised on-device at 77.15.

Tests:
- HangsTests/EarconTests.swift: each capture-phase/command event triggers EXACTLY its earcon; none is emitted during TTS.
- HangsTests/VADConstantsTests.swift: constants are within the documented ranges and consumed by SilenceDetectionService (a min-speech-duration rejects a sub-threshold blip fixture).

Done = `xcodebuild test -only-testing:HangsTests/EarconTests` and `-only-testing:HangsTests/VADConstantsTests` GREEN. Commit per task, push, tick 77.10 + 77.11.
```

---

## Ready prompt — Session 6 (Pencil design update — MCP tools ONLY)

```
Work on issue #77, Session 6 only: 77.12 — update the Pencil design (design/quiz-agent.pen). This session is INDEPENDENT of the code sessions (no code dependency) and can run any time.

⚠️ HARD RULE: the .pen file is ENCRYPTED. NEVER Read or Grep design/quiz-agent.pen or any .pen file. Use ONLY the "pencil" MCP tools. Your FIRST two calls must be:
1) get_editor_state(include_schema: true)  — you cannot use any other pencil tool without the schema.
2) get_guidelines
Then design against the returned schema.

Read first (for the design intent only — these are markdown, safe to Read):
- docs/issues/issue-77-execution-prompts.md → "Locked decisions" (P4a, P4b, P5).
- docs/issues/issue-77-voice-commands-handsfree.md → the "Pencil design update (IN SCOPE — decision 6)" bullet in ## Scope.

Build (via pencil MCP batch_design etc.):
- A LISTENING INDICATOR distinct from the existing answer-recording LISTENING card, on Question / Confirmation / Result.
- PER-SCREEN command hints: Home "Say 'start'"; Question "Say 'start' / 'repeat' / 'skip'"; Confirmation "Say 'ok' / 'again'"; Result "Say 'next'".
- Rework the ONBOARDING voice explainer to teach the small English command set and note it is ENGLISH-ONLY by design.
- EVERY voice affordance keeps a VISIBLE BUTTON TWIN — the design must not imply voice-only control.

Validate with snapshot_layout / get_screenshot on each updated screen.

Done = get_screenshot of Home/Question/Confirmation/Result each shows the listening indicator, the per-screen hint text, and a visible button twin for every voice affordance; the onboarding screen states English-only. NO .pen file was Read/Grep'd (pencil MCP only). Commit the .pen change, push, tick 77.12.
```

---

## Ready prompt — Session 7 (Doc hygiene + headless verification harness)

```
Work on issue #77, Session 7 only: 77.13 (doc-hygiene + localization sweep) + 77.14 (headless verification harness — this is what gates the loop). Sessions 2-5 must be merged first (77.14 runs all their suites); 77.13 depends on Session 4 having re-wired repeatQuestion(). Stop, commit, push when green.

Read first:
- docs/issues/issue-77-execution-prompts.md → "Recon snapshot" (doc-hygiene targets) + the Session breakdown note on 77.14's 77.6 contingency.
- CONTEXT.md:56 (glossary "voice commands always available"); apps/ios-app/Hangs/Hangs/Views/OnboardingView.swift:295 (`Say "skip", "pass", or "next" anytime`); apps/ios-app/Hangs/Hangs/Utilities/Logging.swift:32 (Logger.voice comment).
- Session 3's Status note on whether 77.6 (VADIsolationTests) is headless or fell to the [HUMAN] fallback.

Build:
1) 77.13 — correct the now-false "voice commands always available" copy to the new English-voice-plus-button reality: CONTEXT.md:56 glossary, OnboardingView.swift:295, Logging.swift:32 Logger.voice comment; remove/replace the dead repeatQuestion() doc reference (Session 4 re-wired it). Any NEW user-facing string routes through the English-source Localizable.xcstrings flow (#56; Slovak UI translation stays deferred). Earcons stay language-neutral (no strings).
2) 77.14 — ensure the machine-checkable surface is green as ONE suite: capture-phase (77.4), matcher routing/strict-skip/scoping/undo (77.3), listener windowing + defensive fallback (77.5), single-engine (77.7), start/confirm/result routing (77.8-77.9), earcons (77.10), VAD constants (77.11) — Apple recognizer mocked throughout.
   ⚠️ VADIsolationTests (77.6): include it in the suite ONLY IF Session 3 delivered it as a real headless test. If Session 3 recorded that 77.6 fell to the [HUMAN] fallback, DO NOT invent a headless version — assert only the suites that are genuinely headless and confirm the 77.6 side-by-side detector-timing comparison is recorded in the 77.15 checklist.
   Add/extend the relevant /regression scenario if the listener windowing touches an existing RS flow (esp. RS-05 auto-confirm must still reach its terminal assertion with the sheet listener armed).

Done = `xcodebuild test -only-testing:HangsTests` GREEN (all command suites) AND `cd apps/quiz-agent && pytest tests/ -v` GREEN; `/regression RS-05` reaches its terminal assertion with no REJECTED transitions. Commit per task, push, tick 77.13 + 77.14.
```

---

## Session 8 — 77.15 `[HUMAN]` on-device gate (NOT agent-runnable)

**This is a founder task, run last, on the target iOS 26+ device — non-blocking for Sessions 1–7.** On the device (not the Simulator — `supportedLocales` is empty there):

1. Arm the real `SpeechTranscriber` **and** `DictationTranscriber` (A/B both per delta §B1).
2. Speak each command (**start · ok · next · repeat · skip** [+ optional **stop**]) in the **founder's own Slovak-accented English** and confirm routing. **Swap any word that mis-transcribes** — the set (P4b) is provisional until here.
3. Tune the 77.11 STOP constants against real cabin noise (no clipping of a thinking pause).
4. Verify Bluetooth **HFP/A2DP** mic routing.
5. Confirm phone-call interruption recovery (77.2) leaves no stranded recording.
6. If 77.6 (`VADIsolationTests`) fell to the `[HUMAN]` fallback: record the side-by-side detector-timing comparison here.

Record results in a `docs/testing/runs/RS-*` file or the issue checklist. **#77 is explicitly NOT fully headless-closable — stated, not hidden.**

---

## Status

- ✅ **Recon + split done (this doc, 2026-07-03).** 15 tasks → **7 agent sessions + 1 `[HUMAN]` device gate**. Class `a`, both Phase-5 gates green (READY · SOUND 0.84).
- ✅ **Session 1 delivered 2026-07-03 — Prerequisites** (77.1 #66 guard + 77.2 #67-A teardown). 77.1 → commit `5cabfd8` (#66): early return in `QuizFlowService.process_answer` when `result.evaluation is None`, before the advance block; text `/input` route now 400s like the voice route; new `tests/test_flow_intent_guard.py`; backend suite 256 passed. 77.2 → commit `ce349bd` (#67): `.began` interruptions route through the new pure `AudioService.interruptionTeardown(isStreaming:isRecording:)` — a live streaming engine gets `stopStreamingRecording()`; new `AudioServiceProtocol.onInterruptionBegan` callback (protocol now `AnyObject`-bound), wired in `QuizViewModel.init` to `handleAudioInterruption()` (`.recording` → `.askingQuestion`, streaming STT/timers reset); `MockAudioService` gained `audioEngineActive` + `simulateInterruptionBegan()` (drives the same routing fn); AudioServiceTests file = 7 suites / 24 tests green. *Verification gotchas for later sessions:* `AudioServiceTests.swift` holds multiple `@Suite`s — `-only-testing:HangsTests/AudioServiceTests` matches NOTHING, filter by suite name (e.g. `InterruptionTeardownRoutingTests`); destination needs `OS=18.6` (bare `name=iPhone 16` is ambiguous); scheme is `Hangs-Local` (there is no plain `Hangs` scheme).
- ✅ **Session 2 delivered 2026-07-03 — Pure-logic core** (77.3 matcher + 77.4 capture-phase). 77.3 → commit `e4f3ff6`; 77.4 → commit `900d4af`. Both suites GREEN: **19 tests / 2 suites** (`VoiceCommandMatcherTests` + `CommandCapturePhaseTests`) via `-only-testing:HangsTests/VoiceCommandMatcherTests -only-testing:HangsTests/CommandCapturePhaseTests`. `git diff` of `QuizViewModel.swift` shows **NO new QuizState cases / validTransitions** (only an additive `@Published` phase + method + a comment mentioning the words). *Verification gotcha reconfirmed:* Swift Testing `-only-testing` filters by the **struct type name** (`VoiceCommandMatcherTests`), NOT the `@Suite("display")` string — filtering by the display name yields the `Executed 0` trap.
  - **Exact public signatures Sessions 3/4/5 import:**
    - **Matcher (77.3):** `enum VoiceCommandMatcher { static func match(transcript: String, on screen: VoiceCommandScreen) -> VoiceCommand? }`; also `static func normalize(_:) -> String` and `static func similarity(_:_:) -> Double`; tunables `confidenceFloor = 0.72`, `ambiguityMargin = 0.15`, `skipFloor = 0.8`.
    - **Command grammar:** `enum VoiceCommand: String, CaseIterable { case start, ok, next, again, repeatQuestion, skip, stop }` (note: `.repeatQuestion` = the "repeat" word; `.again` = retry/again on the sheet).
    - **Screen scoping:** `enum VoiceCommandScreen { case home, question, confirmation, result }`. Valid sets — home:[start] · question:[start, repeatQuestion, skip] · confirmation:[ok, again, stop] · result:[next, ok]. `skip` matches STRICT whole-utterance only.
    - **Lexicon (77.3):** `enum VoiceCommandLexicon { static func commands(on:) -> [VoiceCommand]; static func variants(for:) -> [String]; static let fillerWords: Set<String>; static let cancelWords: [VoiceCommand]; static func isCancelWord(_ token: String) -> Bool }` (pass a `VoiceCommandMatcher.normalize`-d token to `isCancelWord`).
    - **Undo window (77.3):** `struct UndoWindow { static let defaultDuration = 2.5; let deadline: Date; init(startedAt: Date = Date(), duration: TimeInterval = 2.5); enum Resolution { case abort, commit }; func isOpen(at now: Date) -> Bool; func resolve(cancelledAt: Date?) -> Resolution }`. Cancel `<= deadline` ⇒ `.abort`; `nil` or late ⇒ `.commit`. Pure — caller supplies timestamps.
    - **Capture-phase (77.4):** `enum CommandCapturePhase: String, CaseIterable { case idle, armed, listening, recording, processing }` + `enum CaptureLifecycleEvent: String, CaseIterable { case arm, listen, recognize, record, process, reset }`; pure transition `CommandCapturePhase.applying(_ event:) -> CommandCapturePhase?` (nil = illegal/no-op). On the VM: `QuizViewModel.commandCapturePhase` (`@Published private(set)`, starts `.idle`) + `@discardableResult func applyCaptureEvent(_ event: CaptureLifecycleEvent) -> Bool` (false + unchanged on an illegal event). Transitions: idle→(arm)armed→(listen)listening; listening→(recognize)listening [ack-only] / →(record)recording→(process)processing; processing→(arm)armed [re-arm]; any→(reset)idle.
- ✅ **Session 3 delivered 2026-07-03 — Audio topology** (77.5 listener + 77.7 single-engine; 77.6 → **[HUMAN]-deferred**). Code commit `4dff2f3` (#77). **CommandListenerTests (11) + SharedEngineTests (3) GREEN** via `-only-testing:HangsTests/CommandListenerTests -only-testing:HangsTests/SharedEngineTests` (14 tests / 2 suites, non-zero). Full `-only-testing:HangsTests` = 465 tests, only the **15 pre-existing** iOS-18.6 failures (`SilenceDetectionServiceTests` withKnownIssue ×10 + Home/Question/Result view-snapshot ×5) — **verified identical on HEAD via stash**, so zero regressions (Session 1's interruption suites + streaming + barge-in all green).
  - **77.6 is [HUMAN]-deferred, NOT headless.** The detector path is iOS 26+ and the headless destination is the iOS **18.6** Simulator, where the whole `#available(iOS 26)` body is skipped — so no `VADIsolationTests.swift` was created (faking two locale configs through the locale-independent decision fn would be a test that cannot fail, Rule #6). The side-by-side detector-timing comparison is recorded as an explicit step in **77.15** (Session 8). *Session 7's 77.14 must therefore assert only the genuinely-headless suites and NOT expect a `VADIsolationTests`.*
  - **Exact public entry points Sessions 4/5 import:**
    - **Recognizer source (77.5):** `SilenceDetectionServiceProtocol.commandTranscripts: AsyncStream<String>` (finalized English transcripts; the real service re-locales the paired transcriber to `en_US`, `reportingOptions: []` = finalized-only). `MockSilenceDetectionService` gained `commandTranscripts`, `simulateCommandTranscript(_:)`, `finishCommandTranscripts()`, and `shouldFailSetup` (simulates a degrade — `startListening()` leaves `isListening == false`).
    - **Window (77.5):** `QuizViewModel.currentCommandScreen: VoiceCommandScreen?` (nil ⇒ don't listen: recording, TTS, and non-interactive states); `QuizViewModel.isRecordingActive: Bool`; `QuizViewModel.isPlayingQuestionTTS: Bool` (set around question/replay TTS). `func syncCommandListenerWindow() async` arms/disarms to match the window; `func refreshCommandWindow()` is its fire-and-forget wrapper (called after entering `.processing` and `.showingResult`).
    - **Consumer + capture (77.5):** the consumer rides `startSilenceDetectionListening()` / `stopSilenceDetectionListening()` (now also start/stop `startCommandConsumer()`/`stopCommandConsumer()` and drive the 77.4 capture phase idle→listening / →idle). `func handleCommandTranscript(_:) async` (screen-scoped match) → `func handleRecognizedCommand(_ command: VoiceCommand)`.
    - **Session 4 wiring seam:** `QuizViewModel.onCommandRecognized: (@MainActor (VoiceCommand) -> Void)?` — Session 3 fires it on every recognized command but performs NO routing. Session 4 binds this (or expands `handleRecognizedCommand`) to route start/ok/next/repeat/skip per screen. New `TaskKey.commandListener`.
    - **77.7 enforcement point:** `startStreamingRecording()` calls `stopSilenceDetectionListening()` before `audioService.startStreamingRecording(...)`. The batch path is untouched (AVAudioRecorder, not a second engine).
    - **⚠️ Scope boundary for Session 4:** the **Home window is NOT production-wired** (no continuous idle-screen mic). `currentCommandScreen` maps `.idle → .home` and `syncCommandListenerWindow` will arm it — the mechanism is delivered and unit-tested — but Session 3 deliberately does NOT auto-arm the mic on the idle Home screen (an always-on-mic product/privacy decision + it belongs with Session 4's spoken-"start"→`startNewQuiz` wiring, P4a). Session 4 should call `syncCommandListenerWindow()` from Home's appearance if/when the founder approves Home listening.
- ✅ **Session 4 delivered 2026-07-03 — Command wiring** (77.8 start-flag + 77.9 confirm/result/repeat/skip). **StartCommandTests (6) + ConfirmResultCommandTests (10) GREEN**, 16 tests / 2 suites non-zero via `-only-testing:HangsTests/StartCommandTests -only-testing:HangsTests/ConfirmResultCommandTests`. Full `-only-testing:HangsTests` = **481 tests, only the 15 pre-existing** iOS-18.6 failures (SilenceDetectionServiceTests ×10 + Home/Question/Result snapshot ×5) — zero regressions.
  - **Routing seam filled:** `handleRecognizedCommand(_:)` now fires `onCommandRecognized` (observation hook, kept) **then** `routeCommand(_:)` (new, in `QuizViewModel+CommandListener.swift`) — a screen-scoped `switch (currentCommandScreen, command)`. Async actions hop to a `Task` so the @MainActor consumer path never blocks. Per screen: home+start→`startNewQuiz`; question+start→`startRecording` (flag-gated); question+repeat→`repeatQuestion`; question+skip→`beginSkipUndoWindow`; confirmation+ok→`confirmAnswer`, +again→`rerecordAnswer`, +stop→`cancelProcessing`; result+next/ok→`continueToNext`.
  - **77.8 flags (founder-overridable, instance props seeded from `Config`):** `QuizViewModel.voiceStartOnQuestionEnabled = Config.voiceStartCommandEnabled` (default ON) gates ONLY question-screen "start"→`startRecording`; OFF leaves the rest of the command layer intact. **No auto-mic-open** — routing only ever runs on a *recognized* command; the TTS-finish path (`startRecordingOrTimer`) is untouched (P1), asserted by `noAutoMicOpen`.
  - **Home wired (default ON, separate flag):** `QuizViewModel.voiceStartOnHomeEnabled = Config.voiceHomeStartEnabled`. `HomeView.onAppear` now calls `refreshCommandWindow()` when the flag is ON, arming the idle-screen listener; home+"start" routes to `startNewQuiz` **regardless of the question flag** (tested). On-device English recognition only.
  - **Dead `repeatQuestion()` re-wired:** question+"repeat" replays the question audio; `playQuestionAudio` re-arms the listener after the replay TTS (durable test signal: `MockAudioService.playOpusCallCount` + `silence.isListening`; `isPlayingQuestionTTS` is only transiently true, so NOT a reliable assertion target — noted for later sessions).
  - **Skip undo-window WIRED (not deferred):** new `QuizViewModel.beginSkipUndoWindow(duration: = UndoWindow.defaultDuration)` opens `@Published private(set) var pendingSkipWindow: UndoWindow?`, schedules a `TaskKey.skipUndo` task that commits via `skipQuestion()` on expiry; `abortSkipUndoWindow()` (tap seam) cancels it. **Session 5 seams left explicit:** `onSkipUndoWindowOpened: (@MainActor () -> Void)?` fires when the window opens (the **skip-confirm earcon** binds here). **DEFERRED to Session 5:** aborting via a *spoken* cancel word ("stop"/"no") *during* the question-screen window — that needs the cancel-word listener path (`VoiceCommandLexicon.isCancelWord`) which ships with the earcons; "stop" is currently only in the confirmation screen's valid set. The tap-abort + timer-commit core is done here.
  - **New symbols Session 5/7 import:** `Config.voiceStartCommandEnabled`, `Config.voiceHomeStartEnabled`; `QuizViewModel.{voiceStartOnQuestionEnabled, voiceStartOnHomeEnabled, pendingSkipWindow, onSkipUndoWindowOpened, beginSkipUndoWindow(duration:), abortSkipUndoWindow(), routeCommand(_:)}`; `TaskKey.skipUndo`.
- ⬜ **Session 5 — Earcons + STOP tuning** (77.10 + 77.11)
- ⬜ **Session 6 — Pencil design** (77.12, MCP-only) — *parallelizable*
- ⬜ **Session 7 — Doc hygiene + headless harness** (77.13 + 77.14) — *77.14 contingent on 77.6's headless/deferred status*
- ⬜ **Session 8 — `[HUMAN]` on-device gate** (77.15) — *last, non-blocking*

> When a session lands, add a *"Session X delivered — exact symbols for Y"* note here (as issue-61 does) so the chain stays decoupled — especially Session 2's matcher/lexicon/capture-phase signatures and Session 3's listener + shared-engine entry points.
