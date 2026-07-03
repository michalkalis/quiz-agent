# Issue #77 — Execution plan + ready-to-paste session prompts

> ## ⚠️ SUPERSEDED 2026-07-03 — do not run Sessions 2–6
> Founder feedback (see the top of [`issue-77-voice-commands-handsfree.md`](issue-77-voice-commands-handsfree.md)) reversed the core design: **no auto-mic START after the question** (the answer timer stays), and **commands are English-only via the native iOS speech framework, not Slovak-via-ElevenLabs**. Only **Session 1 (77.1 + 77.2)** remains valid as written. Everything else awaits a re-planning pass.

**Created:** 2026-07-03 — from the `/prepare-issue` Phase 6 split (recon re-verified against HEAD `864cf1a`, 2026-07-02, by one iOS Explore agent + first-hand backend/iOS spot-checks). #77 is **large** (14 tasks 77.1–77.14, incl. an audio-engine consolidation) but **class `a`** (pure iOS + one tiny backend guard from #66 — no auth / payments / DB schema / migrations). It is split into six agent-runnable, independently-committable sessions plus one final `[HUMAN]` on-device gate. Each session below has a self-contained prompt: open a fresh session, paste the fenced block, go — no access to the authoring chat needed.

> Parent plan: [`issue-77-voice-commands-handsfree.md`](issue-77-voice-commands-handsfree.md). Research report (citations): [`../research/voice-commands-handsfree-research-2026-07-02.md`](../research/voice-commands-handsfree-research-2026-07-02.md).

**Reversibility: class `a`.** The only backend change (77.1) is a control-flow early-return guard in `flow.py` — no schema, no migration, no auth/payments. All other tasks are pure iOS, reusing the existing `POST /api/v1/elevenlabs/token` and `POST /api/v1/sessions/{id}/input` contracts (no new server contract). So Sessions 1–6 are **Ralph-runnable headless**; only 77.14 (real-device VAD / cabin-noise / BT / interruption) carries a human gate — and it is **last and non-blocking** for the headless sessions.

---

## Recon snapshot — what the codebase already gives us

**Verification shorthand** (used in every prompt below):
`xcodebuild test` = `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`, plus the named `-only-testing:` filter.

### Backend (`apps/quiz-agent`) — only 77.1 touches this

- **The submit flow:** `app/quiz/flow.py::process_answer`. After the intent-processing loop, audio-info is built at `:220` (`if include_audio and result.evaluation:`). Then, in order: **max-questions FINISHED** transition at `:226–233`; **usage-limit FINISHED** transition at `:235–254` (the `if not allowed:` block, `session.transition(to=FINISHED, …:usage_limit)` at `:241`); then session-advance — `current_question_id` at `:272`, `asked_question_ids.append` at `:273`, `record_question()` at `:277`.
  - ⚠️ **Guard-placement (Gate-B caution, load-bearing for 77.1):** the task text says "~`:256`", but **both** the max-questions (`:226`) and usage-limit (`:241`) blocks transition to `FINISHED` *before* `:256`. A non-answer intent (`result.evaluation is None`) arriving **at the daily limit** would therefore hit the usage-limit `FINISHED` transition at `:241` — a spurious end-of-quiz — before ever reaching a guard at `:256`. So the guard must sit **right after the audio-info build (~after `:223`) and BEFORE the "Check if quiz is finished" (`:226`) and "Check usage limit" (`:235`) blocks.** See Locked decisions row **G-77.1**.
- **Tests:** `tests/` — pytest, mock OpenAI, fixtures. Run `cd apps/quiz-agent && pytest tests/ -v`. New file for 77.1: `tests/test_flow_intent_guard.py`.

### iOS (`apps/ios-app/Hangs`, Xcode project "Hangs", scheme `Hangs-Local`)

- **Test framework: Swift Testing throughout** (`import Testing` / `@Test`, 51 files; **zero** `XCTest`). Example: `HangsTests/QuizViewModelMCQVoiceTests.swift`. Mocks are **protocol-injected via the `QuizViewModel` initializer** (`QuizViewModel.swift:307–311` service fields, `:336–346` init params); `AppState.swift:24–32` composes real-vs-mock. **`MockSilenceDetectionService` already exists** (`Hangs/Services/Mocks/MockSilenceDetectionService.swift`) — reuse it to inject `SilenceEvent`s; siblings `MockAudioService`, `MockElevenLabsSTTService`, `MockNetworkService` in the same dir.
- **Utilities folder (new files go here, next to the sibling):** `Hangs/Utilities/` — holds `MCQTranscriptMatcher.swift`, `Config.swift`, `AppState.swift`, `Logging.swift`. `VoiceCommandLexicon.swift`, `VoiceCommandMatcher.swift`, `EarconPlayer.swift` land here. **Verified none exist today.**
- **Sibling to mirror — `MCQTranscriptMatcher.swift`:** `enum MCQTranscriptMatcher` (`:16`), `static func match(_ transcript: String, options: [(key: String, value: String)]) -> String?` (`:30`), diacritic-fold `private static func normalize(_:)` (`:70`, `.folding(options: [.diacriticInsensitive, .caseInsensitive], …)`). `VoiceCommandMatcher` is its sibling.
- **Command seam — `QuizViewModel+Recording.swift:173`** `func handleCommittedTranscript(_ text:) async` — the committed transcript arrives here; MCQ match runs at `:204`. New command classification goes **ahead of** the MCQ/answer branches.
- **QuizViewModel.swift anchors:** `func skipQuestion()` at **`:675`** (⚠️ drift — the task's "~`:690`" is a `submitTextInput` call *inside* its body); `func repeatQuestion()` at `:1017` (currently dead — no caller); `silenceDetectionAvailable` at `:1087`. **Note:** `submitTextInput` is a `NetworkService` method, invoked at call sites `:614 / :659 / :690` — all voice/text submits converge on it, so one client-side gate at `handleCommittedTranscript` covers the whole surface.
- **Audio seams:** `QuizViewModel+Audio.swift` — TTS teardown `stopSilenceDetectionListening()` `:84`, re-arm `startSilenceDetectionListening()` `:95` (never arm during TTS — the `1a19438` lesson). `QuizViewModel+Timers.swift` — `startAutoConfirmIfEnabled(duration: Int = Config.autoConfirmDelaySecs)` `:198`, `cancelAutoConfirm()` `:222`.
- **Two `AVAudioEngine`s today (the 77.7 target — spot-checked first-hand):** `grep -rn "AVAudioEngine()"` → exactly **2** sites: `AudioService.swift:609` (streaming; tap `:652`, `self.audioEngine = engine` `:691`, `stopStreamingRecording()` `:704`) and `SilenceDetectionService.swift:125` (VAD; tap `:162`). `SilenceEvent` enum at `SilenceDetectionService.swift:27–29`; `silenceThreshold = 1.5` `:73`; `sensitivityLevel: .medium` `:102`. `ElevenLabsSTTService.swift` **owns no `AVAudioEngine`** (verified zero hits) — it only consumes PCM via `sendAudioChunk(_:)` `:103`.
- **Interruption (77.2 target):** `AudioService.swift` `handleInterruption` `.began` at `:385–388` — today calls only the batch `stopRecording()`, never `stopStreamingRecording()` (`:704`).
- **Config / availability:** `Config.swift` — `autoRecordDelayMs = 500` `:116`, `autoConfirmDelaySecs = 10` `:119`. `AppState.swift:53–56` — real `SilenceDetectionService()` gated by `if #available(iOS 26, *)` else `nil` (the sub-iOS-26 button-start fallback path).
- **Doc-hygiene targets (all stale text confirmed present):** `CONTEXT.md:55–56` ("Voice commands always available. …"), `OnboardingView.swift:293–295` (`Say "skip", "pass", or "next"`), `Logging.swift:31–32` (`Logger.voice` comment).

---

## Locked decisions (carry into every session)

Lifted verbatim by id from the issue's `## Resolved design decisions`, plus the two non-blocking Gate-B cautions folded in as **G-77.1 / G-77.7**.

| # | Decision |
|---|---|
| **1** | **START = automatic, VAD-triggered** after the question TTS, with ~300 ms pre-roll; **no spoken keyword.** *Coordinator-adopted default — **founder-overridable to button-only START before execution** (see Q1 override note below).* On-device Apple speech has no Slovak; a paid wake-word was rejected. |
| **2** | **Barge-in = OUT of scope.** Strict sequencing: TTS finishes → earcon → mic arms. **No AEC / `.voiceChat` / `setPrefersEchoCancelledInput`.** Keep the current `.playAndRecord` + `.spokenAudio` + `.allowBluetoothHFP` + `.duckOthers` session. (Founder-confirmed.) |
| **3** | **Repeat / Skip = spoken during the answer window; Confirm / Re-record = spoken on the confirmation sheet — matched client-side from the ElevenLabs transcript. No new ASR.** Glanceable buttons + the existing 10 s auto-confirm stay as fallback. Skip carries a **strict whole-utterance match + skip-confirm earcon + ~2.5 s undo window**. Repeat is idempotent (no guard, no backend). (Founder-confirmed.) |
| **4** | **GPT-style recording-UI polish = separate follow-up issue** (out of scope; pointer only, file not created here). |
| **Eng — where/how** | Command match is **client-side at `handleCommittedTranscript` (`QuizViewModel+Recording.swift:173`), ahead of the MCQ/answer branches** — a sibling of `MCQTranscriptMatcher`. Backend intent-classification routing was **rejected** (round-trip + walks straight into #66). |
| **Eng — engine** | **One shared `AVAudioEngine` + one input tap** fanning PCM to (a) the `SpeechDetector` VAD (iOS 26 only) and (b) a ~300 ms pre-roll ring buffer that ElevenLabs streaming drains (pre-roll → live) on `speechStarted`. **Never two concurrent engines.** |
| **Eng — lexicon** | Screen-scoped Slovak word lists: Repeat {zopakuj, zopakuj otázku, opakuj} · Skip {preskoč, preskočiť, ďalšia, ďalšia otázka} · Confirm {potvrď, pošli, áno, ok} · Re-record {znova, ešte raz, nahrať znova} · Undo {späť, nie, zruš}. Screen scoping disambiguates ("ešte raz" = re-record only on the sheet). A recognition lexicon (tracks STT content-language), **not** a UI-string catalog. |
| **Eng — VAD params** | Silence hangover **~1.2–1.8 s** (keep near 1.5 s); add **min-speech-duration** (reject cough/blip false starts); **pre-roll ~300 ms**; `SpeechDetector.sensitivityLevel` **`.medium → .low`** for road noise; ElevenLabs `vadSilenceThresholdSecs` ~1.5, `minSpeechDurationMs`, `minSilenceDurationMs`. **All are starting points to validate in the car (77.14), not final constants.** |
| **Eng — state** | One additive `@Published` **capture-phase** (`idle → armed → listening → recording → processing`) on `QuizViewModel` as the single source of truth for earcons + the deferred UI. **Do NOT add `QuizState` cases or `validTransitions` churn** (would churn the RS suite). |
| **Eng — localization** | Earcons are **language-neutral tones** (no words). Any new user-facing string goes through the existing English-source `Localizable.xcstrings` flow (#56). |
| **G-77.1** *(Gate-B caution, folded in)* | The `if result.evaluation is None: return result` guard for 77.1 belongs **after the audio-info build (~after `flow.py:223`) and BEFORE the max-questions `:226` and usage-limit `:235` blocks** — **not** at `~:256`. Otherwise a non-answer intent at the daily limit triggers a spurious `FINISHED` transition (`:241`) before the guard runs. |
| **G-77.7** *(Gate-B caution, folded in)* | 77.7 (single-engine consolidation) is the **largest/riskiest** task → **its own session (Session 4)** with the **full `xcodebuild test` suite** as the gate (not just a filter) plus the `grep -c "AVAudioEngine()"` → 0 acceptance check. |

**Founder Q1 override note (locked ordering).** If the founder overrides decision 1 to **button-only START** before execution: **drop Session 5 (77.8 + 77.9) entirely** — pre-roll + auto-arm glue. **Session 4 (77.7) stays regardless** (it removes a live crash surface). The spoken-command layer (Sessions 2 + 3, tasks 77.3–77.6, 77.10) is **unaffected**. Session 5 is deliberately scoped to exactly the two override-droppable tasks so the override is a clean "skip Session 5".

**Commit scopes.** 77.1 commits under **#66** (`fix(backend): #66 …`); 77.2 commits under **#67** (`fix(ios): #67 … (Part A)`). Everything else commits under **#77** (`feat(ios)` / `test(ios)` / `docs`).

---

## Session breakdown

| Session | Tasks | Risk | Depends on / parallel |
|---|---|---|---|
| **1 — Prerequisites (#66 + #67-A)** | 77.1 (backend early-return guard) · 77.2 (iOS interruption teardown covers streaming) | Med | none. **Blocks S4** (77.7 must not regress 77.2). May run ∥ with S2. |
| **2 — Command / phase / earcon primitives** | 77.3 (lexicon + `VoiceCommandMatcher`) · 77.4 (capture-phase observable) · 77.5 (`EarconPlayer`) | Low | none — pure new utilities + one additive `@Published`. May run ∥ with S1. **Blocks S3, S5.** |
| **3 — Command routing (answer window + sheet)** | 77.6 (Repeat/Skip + undo) · 77.10 (confirmation-sheet Confirm/Re-record window) | Med | **S2.** Independent of S4/S5 → **may run ∥ with S4.** Blocks S6 (via 77.12). |
| **4 — Single-engine consolidation** ⚠️ **biggest** | 77.7 (one `AVAudioEngine` + one tap) | **HIGH** | **S1** (must not regress 77.2). **Full-suite gate.** Blocks S5, S6. |
| **5 — Pre-roll + VAD auto-arm START** | 77.8 (pre-roll ring buffer) · 77.9 (auto-arm + defensive fallback) | Med-High | **S4 + S2.** *(Dropped entirely on the Q1 button-only override.)* Blocks S6. |
| **6 — Tuning + sim-e2e + docs/localization** | 77.11 (cabin-noise constants) · 77.12 (sim e2e assumption-gate) · 77.13 (doc + localization sweep) | Low-Med | **S3 + S4 + S5.** Last agent session. |
| **`[HUMAN]` — on-device gate** | 77.14 (batched device pass) | — | **all above; non-blocking.** Founder-only. See below. |

**Suggested ordering for a serial (Ralph) run:** S1 → S2 → S3 → S4 → S5 → S6 → `[HUMAN]`. Where two contexts are available, S2 ∥ S1 and S3 ∥ S4 are safe.

---

## `[HUMAN]` device gate — task 77.14 (last, non-blocking)

**This is not an agent session** — it needs the founder + a real device + a car, and cannot be headless (`SpeechTranscriber.supportedLocales` is empty on the Simulator; `SpeechDetector` runs only on device). It **does not block** Sessions 1–6 landing green. Flag for the founder once Session 6 is merged.

1. Trigger a TestFlight build via `/testflight` (fastlane + match) and install on the iOS 26+ device.
2. **VAD START end-to-end (device-only):** after a question, confirm the real `SpeechDetector` arms → `speechStarted` on first speech → silence-stop fires. No crash, no clipped first word.
3. **Cabin-noise validation (real car) of the 77.11 constants:** no clipped first syllable, no premature stop mid-answer, no false start from road noise. Adjust the hangover / `sensitivityLevel` / min-speech-duration starting points and record the tuned values back into this issue.
4. **Bluetooth routing:** HFP + A2DP mic/output route correctly (AirPods / car).
5. **Interruption recovery:** a phone call mid-question recovers cleanly (also closes #67's `[HUMAN]` line).
6. **77.12 e2e fallback, if taken:** if Session 6 recorded "ElevenLabs streaming unusable on the Simulator," run the command-routing e2e here on device instead.

**Done =** founder sign-off recorded in `issue-77-voice-commands-handsfree.md`.

---

## Ready prompt — Session 1 (Prerequisites: #66 guard + #67-A teardown)

```
Work on issue #77, Session 1 only: the two hard-prerequisite bug fixes that every later #77 session depends on — 77.1 (#66 backend ghost-question guard) + 77.2 (#67 Part A: interruption teardown covers streaming). Do NOT build any command/earcon/engine work — that's Sessions 2+. Commit the two under their OWN issue numbers (#66, #67), not #77. Stop, commit, push when both are green.

Read first (already mapped — do not re-map):
- docs/issues/issue-77-execution-prompts.md → "Recon snapshot" (Backend + iOS interruption) + "Locked decisions" rows G-77.1 and commit-scopes. Follow G-77.1 exactly on guard placement.
- apps/quiz-agent/app/quiz/flow.py → process_answer, lines ~220–277 (audio build :220, max-questions FINISHED :226, usage-limit FINISHED :235–254, session-advance :272–277).
- apps/quiz-agent/tests/ → pytest style (mock OpenAI, fixtures); write tests/test_flow_intent_guard.py.
- apps/ios-app/Hangs/Hangs/Services/AudioService.swift → handleInterruption .began :385–388, stopStreamingRecording() :704, self.audioEngine :691.
- apps/ios-app/Hangs/HangsTests/AudioServiceTests.swift → Swift Testing patterns + MockElevenLabsSTTService.

Build:
1) 77.1 (#66) — In flow.py process_answer, add `if result.evaluation is None: return result` IMMEDIATELY AFTER the audio-info build (after ~:223) and BEFORE the "Check if quiz is finished" (:226) AND "Check usage limit" (:235) blocks — per G-77.1, so a non-answer intent at the daily limit cannot fire a spurious FINISHED transition. Give the text /input path the same guard with a meaningful error; the voice route must surface its 400 with NO state mutation. New test tests/test_flow_intent_guard.py: a non-answer intent leaves session.current_question_id unchanged, never calls record_question(), and surfaces the error with the session still on the original question — assert this holds even when the user is at the daily usage limit (regression for G-77.1).
2) 77.2 (#67 Part A) — In AudioService.swift handleInterruption .began (:385–388): when audioEngine != nil, call stopStreamingRecording() (:704) in addition to the existing batch stop, and notify QuizViewModel to leave .recording + reset streaming state. Extend HangsTests/AudioServiceTests.swift + a VM state assertion: a simulated interruption during active streaming → audioEngine == nil, isRecording == false, VM out of .recording.

Done =
- 77.1: `cd apps/quiz-agent && pytest tests/ -v` GREEN including test_flow_intent_guard.py; ruff clean.
- 77.2: `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:HangsTests/AudioServiceTests` GREEN.
Commit 77.1 as `fix(backend): #66 — voice-submit ghost question early-return guard` and 77.2 as `fix(ios): #67 (Part A) — interruption teardown covers streaming path`. Push to main. Tick 77.1 + 77.2 in docs/issues/issue-77-voice-commands-handsfree.md and mark them ✅ in the Status table of issue-77-execution-prompts.md. These are correctness backstops — fail loud, no skipped tests.
```

---

## Ready prompt — Session 2 (Command / phase / earcon primitives)

```
Work on issue #77, Session 2 only: the three standalone primitives every routing session imports — 77.3 (Slovak lexicon + VoiceCommandMatcher), 77.4 (capture-phase observable), 77.5 (EarconPlayer). Do NOT wire them into the recording flow yet (that's Session 3) and do NOT touch the audio engine (Session 4). Stop, commit, push when green. Independent of Session 1 — needs nothing merged first.

Read first (already mapped):
- docs/issues/issue-77-execution-prompts.md → "Recon snapshot" (iOS) + "Locked decisions" (Eng — lexicon, Eng — state, Eng — localization).
- apps/ios-app/Hangs/Hangs/Utilities/MCQTranscriptMatcher.swift → the sibling to mirror: `enum` (:16), `static func match(_:options:)` (:30), diacritic-fold `normalize(_:)` (:70). New files go in this same Utilities/ folder.
- apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift → :307–346 (service fields + init) and where @Published state lives; SilenceEvent enum in Services/SilenceDetectionService.swift:27–29.
- apps/ios-app/Hangs/Hangs/Services/Mocks/MockSilenceDetectionService.swift → inject SilenceEvents in 77.4 tests.
- apps/ios-app/Hangs/HangsTests/QuizViewModelMCQVoiceTests.swift → Swift Testing (@Test) idiom.

Build:
1) 77.3 — Hangs/Utilities/VoiceCommandLexicon.swift (screen-scoped word lists from Locked-decisions "Eng — lexicon": Repeat · Skip · Confirm · Re-record · Undo) and Hangs/Utilities/VoiceCommandMatcher.swift — diacritic-fold + tiered match, sibling of MCQTranscriptMatcher, with the STRICT WHOLE-UTTERANCE rule for Skip (the transcript must BE a skip phrase modulo filler, not merely contain "preskoč"). HangsTests/VoiceCommandMatcherTests.swift: all five groups match after diacritic-fold; "to sa nedá preskočiť" is NOT a skip; "ešte raz" = re-record only in sheet scope (never repeat in answer scope); non-commands return no match.
2) 77.4 — an additive `@Published` capture-phase (idle → armed → listening → recording → processing) on QuizViewModel. NO new QuizState cases, NO validTransitions churn. Transition it from the existing seams (QuizViewModel+Audio.swift :84/:95, QuizViewModel+Recording.swift). HangsTests/QuizViewModelCapturePhaseTests.swift driving injected SilenceEvents (.speechStarted / .silenceAfterSpeech(duration:)) through MockSilenceDetectionService.
3) 77.5 — Hangs/Utilities/EarconPlayer.swift: four language-neutral tones — micLive, gotIt, commandAck, skipConfirm — injectable (protocol) so tests can spy; triggered from capture-phase transitions + command events. HangsTests/EarconPlayerTests.swift: a spy asserts the phase/event → earcon mapping. Tones only, no speech.

Done = `xcodebuild test` (shorthand in the execution-prompts recon) with `-only-testing:HangsTests/VoiceCommandMatcherTests -only-testing:HangsTests/QuizViewModelCapturePhaseTests -only-testing:HangsTests/EarconPlayerTests` all GREEN; build clean. Commit per primitive (`feat(ios): #77 — VoiceCommandMatcher + Slovak lexicon`, `feat(ios): #77 — capture-phase observable`, `feat(ios): #77 — EarconPlayer`). Push. Tick 77.3/77.4/77.5 in issue-77-voice-commands-handsfree.md and Status here.
```

---

## Ready prompt — Session 3 (Command routing — answer window + confirmation sheet)

```
Work on issue #77, Session 3 only: wire the Session-2 primitives into the recording flow — 77.6 (answer-window Repeat/Skip + undo) + 77.10 (confirmation-sheet Confirm/Re-record window). Session 2 (VoiceCommandMatcher, capture-phase, EarconPlayer) must be merged first. Do NOT touch the audio engine (Session 4) or add pre-roll/auto-arm (Session 5). Stop, commit, push when green.

Read first (already mapped):
- docs/issues/issue-77-execution-prompts.md → "Recon snapshot" (iOS command seam + timers) + "Locked decisions" (decision 3, Eng — where/how).
- apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel+Recording.swift → handleCommittedTranscript (:173); MCQTranscriptMatcher call (:204) — insert command classification AHEAD of the MCQ/answer branches.
- apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift → repeatQuestion() (:1017, currently DEAD — wire it), skipQuestion() (:675 — note: the ~:690 anchor is a submitTextInput call inside its body), submitTextInput call sites (:614/:659/:690).
- apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel+Timers.swift → auto-confirm (:198) / cancelAutoConfirm (:222) — the sheet's 10 s default.
- The Session-2 modules: VoiceCommandMatcher, VoiceCommandLexicon, EarconPlayer, capture-phase.

Build:
1) 77.6 — In handleCommittedTranscript, classify the committed transcript via VoiceCommandMatcher (answer scope) BEFORE the MCQ/answer branches. Repeat → wire the dead repeatQuestion() (:1017) to replay question audio + re-arm (pure client action, NO POST). Skip → skipConfirm earcon + a ~2.5 s undo window (spoken "späť/nie" or a tap cancels) BEFORE skipQuestion() (:675) POSTs. Non-command falls through unchanged to the existing answer path. Add the Rule-#11 one-liner comment beside the undo-window constant: the window holds the already-open ElevenLabs stream ~2.5 s longer — no new streaming sessions. HangsTests/QuizViewModelCommandRoutingTests.swift (spy on networkService.submitTextInput): "zopakuj" replays + re-arms with ZERO submits; "preskoč" POSTs skip only after the window elapses; "späť"/tap in-window cancels with ZERO network calls; a normal answer still submits.
2) 77.10 — When AnswerConfirmationView appears, open a short listening window on the SAME ElevenLabs streaming path: Confirm lexicon → confirm; Re-record lexicon → re-record. Keep the 10 s auto-confirm (Config.autoConfirmDelaySecs) as the no-speech default and the sheet buttons as fallback. Tests: spoken confirm/re-record route correctly; with no speech the 10 s auto-confirm still fires; buttons unregressed.

Done = `xcodebuild test -only-testing:HangsTests/QuizViewModelCommandRoutingTests` GREEN + the sheet tests GREEN + `/regression` RS-05..RS-08 GREEN (buttons unregressed). Commit (`feat(ios): #77 — answer-window Repeat/Skip command routing + undo`, `feat(ios): #77 — confirmation-sheet Confirm/Re-record window`). Push. Tick 77.6/77.10 + Status.
```

---

## Ready prompt — Session 4 (Single shared AVAudioEngine — the architecture pin) ⚠️ biggest/riskiest

```
Work on issue #77, Session 4 only: task 77.7 — converge the two AVAudioEngines onto ONE engine + ONE input tap. This is the largest, riskiest task (Gate-B G-77.7): it gets a full-suite gate. Session 1 (77.2 interruption teardown) must be merged first, and you MUST NOT regress it. Do NOT add pre-roll or auto-arm yet — that's Session 5 (this session keeps the existing arm/stream trigger points working through the new shared tap). Stop, commit, push only when the WHOLE suite is green.

Read first (already mapped):
- docs/issues/issue-77-execution-prompts.md → "Recon snapshot" (the two-engines paragraph) + "Locked decisions" (Eng — engine, G-77.7).
- apps/ios-app/Hangs/Hangs/Services/SilenceDetectionService.swift → AVAudioEngine (:125), tap (:162), SpeechDetector wiring, sub-iOS-26 behaviour.
- apps/ios-app/Hangs/Hangs/Services/AudioService.swift → AVAudioEngine (:609), tap (:652), self.audioEngine (:691), startStreamingRecording, stopStreamingRecording (:704), handleInterruption .began (:385–388 — 77.2's teardown must still hold).
- apps/ios-app/Hangs/Hangs/Services/ElevenLabsSTTService.swift → sendAudioChunk(_:) (:103); it owns NO engine — it just consumes PCM.
- HangsTests/AudioServiceTests.swift + HangsTests/SilenceDetectionServiceTests.swift.

Build (77.7): one shared AVAudioEngine + one input tap that fans PCM to (a) the SpeechDetector analyzer input (iOS 26 only — detector fan-out optional so the owner still works sub-iOS-26) and (b) a consumer feeding ElevenLabsSTTService.sendAudioChunk. startStreamingRecording MUST NO LONGER instantiate an engine — it consumes the shared tap. Preserve 77.2's interruption teardown (streaming stop + engine nil). Update SilenceDetectionServiceTests + AudioServiceTests for the shared-tap topology.

Done =
- Full suite: `cd apps/ios-app/Hangs && xcodebuild test -scheme Hangs-Local -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` GREEN (not just a filter — the whole HangsTests suite, per G-77.7).
- `grep -c "AVAudioEngine()" apps/ios-app/Hangs/Hangs/Services/AudioService.swift` → 0.
- 77.2's interruption test still GREEN (no regression).
Commit `feat(ios): #77 — single shared AVAudioEngine + one input tap (architecture pin)`. Push. Tick 77.7 + Status. This removes a live crash surface (#64) — if the full suite is not clean, do NOT commit; diagnose first.
```

---

## Ready prompt — Session 5 (Pre-roll ring buffer + VAD auto-arm START)

```
Work on issue #77, Session 5 only: the START-side glue riding on the Session-4 shared engine — 77.8 (pre-roll ring buffer) + 77.9 (VAD auto-arm START + defensive fallback). Session 4 (single shared engine) AND Session 2 (capture-phase + EarconPlayer) must be merged first. Do NOT tune VAD constants (that's 77.11 in Session 6). Stop, commit, push when green.

⚠️ FOUNDER Q1 OVERRIDE CHECK — do this FIRST: if the founder has overridden decision 1 to button-only START, SKIP THIS ENTIRE SESSION (77.8 + 77.9 are exactly the override-droppable tasks). Session 4 (77.7) already shipped and stays. If auto-VAD START is still the plan (the default), proceed.

Read first (already mapped):
- docs/issues/issue-77-execution-prompts.md → "Locked decisions" (decision 1, Eng — engine, Eng — VAD params) + "Founder Q1 override note".
- apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel+Audio.swift → TTS teardown (:84 — NEVER arm during TTS, the 1a19438 lesson), re-arm seam (:95).
- apps/ios-app/Hangs/Hangs/Utilities/Config.swift → autoRecordDelayMs (:116).
- apps/ios-app/Hangs/Hangs/Utilities/AppState.swift → silenceDetectionService nil on sub-iOS-26 (:53–56); QuizViewModel.swift silenceDetectionAvailable (:1087).
- The Session-4 shared tap + Session-2 capture-phase / EarconPlayer.

Build:
1) 77.8 — a ~300 ms pre-roll ring buffer fed from the Session-4 shared tap; on speechStarted, drain pre-roll THEN live frames into ElevenLabsSTTService.sendAudioChunk. Add `preRollMs = 300` to Config.swift, commented as a starting point pending car validation (77.14). HangsTests/PreRollBufferTests.swift with injected PCM frames: the buffer retains only the window; drain order is pre-roll → live.
2) 77.9 — arm the detector only AFTER TTS completion + a micLive earcon (re-arm seam :95; TTS teardown at :84 stays — never arm during TTS; respect Config.autoRecordDelayMs). On .speechStarted, start ElevenLabs streaming from the shared tap with pre-roll; a min-speech-duration guard CANCELS (never submits) on a cough/blip. A detector setup failure/throw (CARQUIZ-3-class drift) or silenceDetectionService == nil degrades to manual mic-button START without crashing. Extend HangsTests/QuizViewModelCapturePhaseTests.swift: no arming while TTS plays; a sub-min-speech blip returns to armed with NO submit; the fallback path reaches button-start.

Done = `xcodebuild test -only-testing:HangsTests/PreRollBufferTests -only-testing:HangsTests/QuizViewModelCapturePhaseTests` GREEN; build clean. Commit (`feat(ios): #77 — pre-roll ring buffer`, `feat(ios): #77 — VAD auto-arm START + defensive fallback`). Push. Tick 77.8/77.9 + Status.
```

---

## Ready prompt — Session 6 (Cabin-noise tuning + sim e2e assumption-gate + docs/localization)

```
Work on issue #77, Session 6 only: close-out — 77.11 (cabin-noise tuning constants) + 77.12 (sim e2e command routing, assumption-gated) + 77.13 (doc hygiene + localization sweep). Sessions 3, 4, 5 must be merged first (this session tunes/verifies/documents the finished feature). Stop, commit, push when green (or with the 77.12 negative explicitly recorded — see below).

Read first (already mapped):
- docs/issues/issue-77-execution-prompts.md → "Locked decisions" (Eng — VAD params, Eng — localization) + "Recon snapshot" (doc-hygiene targets).
- apps/ios-app/Hangs/Hangs/Services/SilenceDetectionService.swift → silenceThreshold (:73), sensitivityLevel .medium (:102); apps/ios-app/Hangs/Hangs/Services/ElevenLabsSTTService.swift session params.
- CONTEXT.md:55–56; apps/ios-app/Hangs/Hangs/Views/OnboardingView.swift:293–295; apps/ios-app/Hangs/Hangs/Utilities/Logging.swift:31–32; apps/ios-app/Hangs/Hangs/Localizable.xcstrings.
- Backend token route for 77.12: POST /api/v1/elevenlabs/token (backend on :8002, `cd apps/quiz-agent && uvicorn app.main:app --reload --port 8002`).

Build:
1) 77.11 — SilenceDetectionService.swift: keep silenceThreshold within the 1.2–1.8 s band, set sensitivityLevel .medium → .low, add a min-speech-duration constant; ElevenLabs params (vadSilenceThresholdSecs ~1.5, minSpeechDurationMs, minSilenceDurationMs) in ElevenLabsSTTService.swift. Comment ALL as starting points pending 77.14 car validation. Update SilenceDetectionServiceTests.
2) 77.12 — STEP 1 (assumption check): a smoke test opens a REAL ElevenLabs streaming session on the sim (token via POST /api/v1/elevenlabs/token, backend on :8002) and receives a committed transcript from played Slovak audio. IF THIS FAILS on the sim: record the verified negative in issue-77-voice-commands-handsfree.md and MOVE the e2e to the 77.14 [HUMAN] gate — that is the defined fallback (do not force it green). STEP 2 (only if step 1 passes): an env-gated (ELEVENLABS_E2E=1) e2e — audio → ElevenLabs transcript → matcher → route (repeat, skip+undo, confirm, re-record, answer fall-through), Apple detector mocked. Keep the default suite hermetic (no streaming minutes when the flag is unset).
3) 77.13 — Fix CONTEXT.md:55–56 ("always available" → the voice-plus-button reality), OnboardingView.swift:293–295 (new command copy as string literals so keys land in Localizable.xcstrings per #56), Logging.swift:31–32 stale Logger.voice comment; drop the "repeatQuestion() has no caller" stale comments (77.6 wired it). Confirm every new user-facing string from Sessions 2–5 has a key in Hangs/Localizable.xcstrings.

Done =
- 77.11: `xcodebuild test -only-testing:HangsTests/SilenceDetectionServiceTests` GREEN + file inspection (hangover 1.2–1.8 s, .low, min-speech constant present).
- 77.12: the ELEVENLABS_E2E=1 run GREEN — OR the verified negative recorded in issue-77-voice-commands-handsfree.md with the e2e listed under 77.14.
- 77.13: `grep "always available" CONTEXT.md` → no match; new keys present in Localizable.xcstrings; `xcodebuild` build GREEN.
- Full `/regression` RS-01..RS-18 GREEN; no new QuizState cases in validTransitions (file inspection of QuizViewModel.swift).
Commit (`feat(ios): #77 — cabin-noise tuning constants`, `test(ios): #77 — sim e2e command routing (assumption-gated)`, `docs: #77 — voice-command doc + localization sweep`). Push. Tick 77.11/77.12/77.13 + Status. Then flag the 77.14 [HUMAN] device gate to the founder (it does not block this session landing).
```

---

## Status

- ✅ Recon done (this doc) — anchors re-verified against HEAD `864cf1a` (2026-07-02); iOS engine-count + matcher API + guard placement spot-checked first-hand. Class guard: **`a`** confirmed (only backend change is a `flow.py` control-flow guard; no schema/migration/auth/payments).
- ⬜ **Session 1 — Prerequisites (77.1 #66 + 77.2 #67-A)**
- ⬜ **Session 2 — Command/phase/earcon primitives (77.3 + 77.4 + 77.5)**
- ⬜ **Session 3 — Command routing (77.6 + 77.10)**
- ⬜ **Session 4 — Single shared AVAudioEngine (77.7)** ⚠️ full-suite gate
- ⬜ **Session 5 — Pre-roll + VAD auto-arm START (77.8 + 77.9)** *(dropped on Q1 button-only override)*
- ⬜ **Session 6 — Tuning + sim-e2e + docs/localization (77.11 + 77.12 + 77.13)**
- ⬜ **`[HUMAN]` device gate — 77.14** (last, non-blocking; founder-only)

When a session lands, note here any exact new symbols a later session imports (e.g. "Session 2 delivered — `VoiceCommandMatcher.match(_:scope:)` signature for Sessions 3/5") so the chain stays decoupled, as the issue-61 doc does.
