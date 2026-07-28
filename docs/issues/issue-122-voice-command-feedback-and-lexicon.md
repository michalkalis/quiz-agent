# Issue 122: Voice commands: no recognition feedback + reconsider the Slovak "štart" wake word

**Triage:** enhancement · needs-triage
**Status:** Filed 2026-07-28 from the founder's TestFlight field test. Both halves CONFIRMED against the code (Track A: no visual match/no-match state exists; Track B: one shared `.start` word drives both quiz-start and recording-start). Track B is a founder wording decision that [#120 — Transcriber abstraction + Slovak voice commands](issue-120-transcriber-abstraction-slovak-commands.md) explicitly reserved for him; Track A needs a design pass before any code. Needs `/prepare-issue` before an agent run. **2026-07-28: Track A design gate PASSED — founder picked Variant C "Ambient glow" from the HTML variants; see [ui-variants-2026-07-28-decisions.md](../design/ui-variants-2026-07-28-decisions.md) (rule V1: this treatment owns voice-command feedback app-wide). Next: Pencil sync, then code.**
**2026-07-28 (evening): Track A IMPLEMENTED** — `VoiceFeedbackPhase` (idle/matched/unmatched) on `VoiceCommandCoordinator` (+Feedback policy extension), driven off the `.commandAck` seam and the unmatched-final path with the locked variant-page throttle (content-bearing finals only, once per 4 s, never same transcript twice in a row); matched holds a 600 ms floor / 2.0 s ceiling, cleared early by the quiz-state "action landed" hook. Reusable views `AmbientGlowWash` + `GlowSweepLine` (`VoiceFeedbackGlow.swift`) wired into QuestionView (wash, sweep, teal progress tint, Record ring); `CmdListenBar` gained lit/lit-miss feedback states + command-language caption (`POČÚVAM PRÍKAZY`, closes the localization gap) and passes the phase on Home/Result/Confirmation. Presentation-only (listener never suppressed). 21 new tests green (`VoiceFeedbackGlowTests`, `CmdListenBarInspectorTests`); sim visual check passed dark+light via `--ui-test-glow-matched`/`--ui-test-glow-unmatched` seed flags. **Track B (wake word) stays open — founder decisions 1, 2, 4 unresolved.**
**Created:** 2026-07-28

## Symptom

Founder, TestFlight, 2026-07-28, driving in Slovak mode (`dictation-sk` engine, shipped in #120):

**(a) No visual feedback for recognition.** "Slovak voice commands work quite well, though I could imagine slightly better recognition. Visual feedback is missing when a command IS recognized, and when it is NOT. When it recognizes, a loading state should appear in that view so I don't repeat the command." — i.e. after speaking he has no on-screen way to tell whether the app heard him, so he repeats himself.

**(b) "štart" is the wrong word for starting a recording.** "I don't like 'štart' for starting a recording. 'začni' or 'nahrať' or something else would be better."

No screenshots attached; the report is a driving-seat observation.

## Root cause

**Track A — CONFIRMED, the feedback states do not exist.**
`CommandCapturePhase` models only `idle → armed → listening` (`apps/ios-app/Hangs/Hangs/ViewModels/CommandCapturePhase.swift:18-22`); the `.recognize` event is wired as a deliberate no-op — `case (.listening, .recognize): return .listening // ack only — no phase change` (`:43`). It is fired at `VoiceCommandCoordinator+Utterance.swift:330` purely as the earcon seam, and the only consequence of a match is an **audio** cue: `emitEarcon(.commandAck)` (`VoiceCommandCoordinator+Routing.swift:196-202`). The on-screen cue `commandListenerHint` derives solely from `commandCapturePhase == .listening` (`VoiceCommandCoordinator+Listening.swift:56-65`), so `CmdListenBar` (`Views/Components/Hangs/CmdListenBar.swift`) renders the identical static bar before, during and after a command fires — it has no busy/error variant at all.

The **not-recognized** path is quieter still: an unmatched transcript only writes a sampled Sentry log ("voice cmd transcript unmatched", `VoiceCommandCoordinator+Routing.swift:98-109`) and returns — zero user-facing feedback, audio or visual.

Nuance the fix must respect: the screen *does* eventually change for most commands (a routed `.start`/`.skip`/`.next` moves `quizState`, which re-renders or hides the bar). The gap is the **latency window** between "recognized" and "the action visibly lands" — network/TTS-bound for `startRecording()`/`repeatQuestion()` — plus the total absence of any signal when nothing matched. That window is what makes the founder repeat himself.

Historical note: richer `.recording`/`.processing` phases existed in the original #77 design and were deleted as unreachable dead code in [#113 — QuizViewModel decomposition](issue-113-quizviewmodel-decomposition.md) (`CommandCapturePhase.swift:11-12`). Any new state must be driven off a real recognizer signal, not re-added speculatively.

**Track B — CONFIRMED, one word does double duty.**
`VoiceCommandLexicon.commands(on:)` scopes `.start` to both `.home` and `.question` (`Utilities/VoiceCommandLexicon.swift:52-59`) with a single shared variant list; the Slovak variant is `["start"]` because "štart" diacritic-folds to it, kept identical across languages on purpose "to keep founder muscle memory intact" (`:91-93`). `routeCommand` shows the two different actions the one word drives (`VoiceCommandCoordinator+Routing.swift:220-228`): `(.home, .start) → startNewQuiz()`, `(.question, .start) → startRecording()` (the latter additionally gated on `voiceStartOnQuestionEnabled`, default `true` via `Config.voiceStartCommandEnabled`, `Utilities/Config.swift:160`). So there is no schema slot for a screen-specific word today — changing only the recording-start word implies splitting `.start`.

**Corrections to the prior investigation** (verified here, minor but load-bearing for design):
- The claim that the bar "never changes" is true of `CmdListenBar` itself, but the *screen* does change once an action lands. The defect is the un-signalled latency window and the silent no-match path, not a permanently frozen UI.
- `CmdListenBar`'s own doc comment still asserts the command grammar is "English-only by design"; that is stale post-#120 — `VoiceCommandLexicon.hint(on:language:)` returns Slovak hints (`:185-188`). But the bar's caption **"LISTENING FOR COMMANDS" is hardcoded English** and stays English in Slovak mode — a localization gap the design pass should settle at the same time.
- The `(.question, .start)` route is behind a build flag; a lexicon change must keep that path intact.

## Scope of a fix

**Gate (blocking, founder requirement): a proper design pass before any Track A implementation.** No code on Track A before sign-off.

**Process — founder decision 2026-07-28, applies to every UI issue: HTML variants first, Pencil second, code third.** The agent generates several *HTML* variants of the screen/component, the founder reviews them and picks one; only the chosen variant is then drawn into Pencil (`design/quiz-agent.pen` — here the existing component `s49sd`), and only after that is it implemented. Never Pencil-first, never code-first. `⌘S` on the `.pen` stays the founder's step.

The design session must answer:

- What does "recognized / working on it" look like — does `CmdListenBar` morph in place (same slot, same size, no layout jump at 90 km/h) or does a separate transient overlay appear?
- Does the recognized state name the command back ("ŠTART ✓") or stay generic ("…")? Naming it doubles as a recognition-quality check for the founder; it costs a localized string per command.
- What does "heard you, didn't understand" look like, and how does it stay non-alarming? Colour semantics vs. the existing teal listening state; must not read as an error/crash while driving.
- How long does each transient state persist, and what does it do if the action lands sooner (recognized → screen change in <200 ms should not flash).
- Does the bar's caption get localized (and the wake-word hint restated) in Slovak mode?
- Glanceability: is any of this legible in a phone-mount peripheral glance, or should the primary "don't repeat yourself" signal be motion/size rather than text?

**Track A — recognition feedback (post-sign-off):**
- A distinct "recognized/busy" signal driven off the same event that already fires `.commandAck` (`VoiceCommandCoordinator+Utterance.swift:330`), and a distinct "heard, not recognized" signal driven off the unmatched-transcript path (`VoiceCommandCoordinator+Routing.swift:98-109`) — both code paths already exist with zero UI wiring.
- A decision on whether "not recognized" fires on **every** unmatched final or is throttled — the mic is open during ordinary Slovak passenger conversation, and #120's own precision-over-recall framing means most utterances are legitimately not commands. An indicator that lights on every sentence is itself a driving distraction.
- A decision on whether the recognized state also briefly suppresses the listener (matching "so I don't repeat the command") or is cosmetic while listening continues — this determines whether the change touches `VoiceCommandCoordinator+Listening.swift` window arming or is presentation-only.

**Track B — start-recording word (founder decision first, then a small lexicon change):**
- Confirm the scope of the complaint (recording-start only vs. both screens) — this decides whether `.start` splits into two lexicon cases or one new word replaces "štart" everywhere.
- Grep the prod/staging Slovak question-and-answer corpus for literal collisions with any candidate word before locking it — none of the candidates have been checked against real question text.
- Update the hint strings (`VoiceCommandLexicon.hint`) and any `contextualStrings` fed to `DictationTranscriber` alongside the variant change.

**Explicitly not in scope:** raising recognition accuracy itself. The founder's "I could imagine slightly better recognition" is the open engine comparison in #120 (DictationTranscriber `firstHypothesisMs`, pending his car legs) — do not retune thresholds here.

## Founder decisions needed

> **2026-07-28:** decision 3 resolved by the HTML variant pick — **Variant C "Ambient glow"** (text-free bottom-third teal wash on match, amber breath on no-match; `docs/design/ui-variants-2026-07-28-decisions.md`). Decisions 1, 2 and 4 remain open.

1. **Which Slovak word starts an answer recording?** Candidates, with tradeoffs (not a pick — #120 reserved this for you):
   - **"spusti"** (imperative of *spustiť*, launch) — idiomatic Slovak tech phrasing, multi-syllable, semantically generic so it can keep covering Home-start-quiz too. Not on your shortlist; surfaced as the strongest single-word-for-both option.
   - **"začni"** (your suggestion) — also generic enough for both screens, but more conversational, so marginally higher false-fire risk in cabin chatter (e.g. "začni odznova" said to a passenger).
   - **"nahraj"** (imperative of your *nahrať*; #120's design rule is imperative, not infinitive) — best semantic fit for recording specifically, lowest ambiguity, but does not map onto "start a quiz", so choosing it implies splitting `.start` into two commands.
   - **"štart"** — the status quo you rejected; listed only as the baseline.
2. **Is the complaint recording-only, or is "štart" also wrong on Home?** Your wording says recording; confirming decides whether we split the lexicon case or do a single global swap (cheaper).
3. **How ambitious is the visual feedback — a two-state flash (recognized / not recognized) or a full `CmdListenBar` state machine (idle / listening / busy / error) with motion?** Your "a loading state should appear so I don't repeat the command" reads as wanting the busy state to actively discourage repeating, which is a UX behaviour call, not a skin.
4. **Should "not recognized" fire on every unmatched utterance, or be throttled in Slovak mode?** Honest feedback vs. an indicator blinking through every passenger sentence.

## Related

- [#120 — Transcriber abstraction + Slovak voice commands](issue-120-transcriber-abstraction-slovak-commands.md) — owns the Slovak lexicon this issue amends, recommended "štart" and explicitly left final wording to the founder; its open engine decision covers the "better recognition" half.
- [#77 — Voice commands hands-free](issue-77-voice-commands-handsfree.md) — built `CommandCapturePhase`, `CmdListenBar` (task 77.12) and the earcon seam (77.10); its unbuilt richer capture UI is the direct ancestor of Track A.
- [#113 — QuizViewModel decomposition](issue-113-quizviewmodel-decomposition.md) — deleted the unreachable `.recording`/`.processing` phases; precedent that any new state must be wired to a real signal.
- [#119 — Voice-command recognition quality](issue-119-voice-command-recognition-quality.md) — the accuracy/threshold work, done; out of scope here.
- [#117 — Voice "start" plays the visible delivered pack](issue-117-voice-start-pack-context.md) — also edits `(.home, .start)` routing; coordinate if both run, but pack context is out of scope here.
- [#105 — Voice commands dead everywhere](issue-105-voice-commands-dead.md) — fixed dead-recognizer bug, unrelated.
