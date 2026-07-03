# Research DELTA — Native English voice commands (issue #77)

**Date:** 2026-07-03 · **Phase:** 1 (delta) of `/prepare-issue` · **Author:** Claude (Opus)
**Issue:** `docs/issues/issue-77-voice-commands-handsfree.md`
**Supersedes (in part):** `docs/research/voice-commands-handsfree-research-2026-07-02.md` — that report stays
valid for the audio-topology recon, the crash/fragility history, and the STOP-on-silence tuning. This delta
only reworks the two things founder feedback 2026-07-03 changed:

1. **START is no longer auto-armed.** Drop the VAD auto-arm / pre-roll START design (old tasks 77.8–77.9).
   After the question TTS finishes the app must **not** open the mic — the existing thinking-timer +
   mic-button flow stays exactly as-is.
2. **Commands are recognised by the NATIVE iOS speech framework, English-only, for all users** —
   `SpeechAnalyzer`/`SpeechTranscriber` (or `DictationTranscriber`) on-device English, **not** matched off
   the Slovak ElevenLabs answer transcript. This invalidates the Slovak-lexicon / transcript-matching design
   (old 77.3, 77.6, 77.10). Command words must be robust to a **Slovak-accented English** speaker — the exact
   failure mode that killed the original `VoiceCommandService` (`c7a001c`).

Still valid regardless: 77.1 (#66 ghost-question guard) and 77.2 (#67-A streaming interruption teardown) as
prerequisites; 77.7 (single shared `AVAudioEngine`) load-bearing but re-validated below against the new
topology.

---

## TL;DR (delta headlines)

1. **The irony is total: we are re-adopting the exact API that was deleted for failing the Slovak user.**
   `VoiceCommandService` used `SpeechTranscriber` hardcoded to `en_US` and never recognised the founder's
   Slovak-accented English commands. The founder now *wants* native English recognition anyway — so the
   whole game is **choosing command words that survive a Slavic accent** and **degrading gracefully**, not
   the recognizer choice (which is locked to Apple native).
2. **No custom-vocabulary API on the new framework.** `SpeechAnalyzer`/`SpeechTranscriber` does **not** expose
   `SFSpeechRecognizer`'s `contextualStrings` custom-vocabulary biasing. You get a raw English transcript and
   match command words client-side (fuzzy) — you cannot bias the model toward "restart" the way legacy could.
   This makes accent-robust word choice + fuzzy matching the entire ballgame.
3. **A tiny fixed English keyword grammar recognised by a general dictation model is brittle** (Apple's own
   Voice Control "may fail at the slightest variation"). Mitigate with: few, phonetically-distinct words;
   fuzzy/phonetic matching (not exact string); and a visible button fallback on every screen.
4. **Windowed, not always-on.** The command listener should be armed only in specific screens/states and torn
   down otherwise — for battery, for self-trigger avoidance during TTS, and because a long-lived streaming
   `SpeechAnalyzer` has documented iOS 26.3 `start(inputSequence:)` failures. START stays button/timer, so
   there is **no** command-listening during the answer-recording window at all (that path is 100% ElevenLabs).
5. **Topology: the English command listener needs its OWN `SpeechTranscriber` consuming the shared tap** —
   but it is NEVER live at the same time as the ElevenLabs answer stream, so the 77.7 single-engine pin still
   holds and actually gets *simpler* (command-listen and answer-stream are time-disjoint, not concurrent).

---

## A. Code recon (delta)

### A1. The deleted `VoiceCommandService` — how it worked and why it failed

*(Deleted wholesale in `c7a001c`, 2026-04-21, 562 lines + `VoiceCommand.swift` model + `QuizViewModel+VoiceCommands.swift`
+ `VoiceCommandIndicator.swift` + 767-line `VoiceCommandTests.swift`. Reconstructed from `git show c7a001c~1:…`.)*

- **API:** iOS 26 `Speech` framework `SpeechAnalyzer` with **two** modules — `SpeechTranscriber` (command
  words) + `SpeechDetector` (VAD) — over one shared `AVAudioEngine` tap (`VoiceCommandService.swift:135-146`).
  NOT legacy `SFSpeechRecognizer` (never used in this app). Transcriber locale **hardcoded `Locale(identifier:
  "en_US")`** (`:136`), not configurable, no fallback. Created with **empty** `transcriptionOptions: []` and
  `reportingOptions: [.volatileResults]` — so no biasing of any kind.
- **Grammar / matching:** `VoiceCommand` was a 13-case enum (`start, stop, skip, repeat, score, help, ok,
  again, home, optionA…D`). Matching was **exact word-boundary** against a `Set<String>` of whitespace-split
  transcript tokens (`VoiceCommand.match(from:)`) — deliberately not substring (to avoid "book"→"ok",
  "helpful"→"help"), with a fixed tie priority. **No fuzzy / Levenshtein / phonetic / synonym layer anywhere.**
  A TTS-echo rejection heuristic (60% word-overlap vs the TTS text) added false negatives on top.
- **Audio:** its own `AVAudioEngine` + `installTap` (`@Sendable` closure + `@preconcurrency import AVFoundation`
  — the CARQUIZ-1 fix was **already present** pre-deletion, so that crash was *not* the removal reason),
  manual `AVAudioConverter` to the analyzer format, `start(inputSequence:)` in its own `Task`, results consumed
  via `for try await` and re-dispatched through `MainActor.run`. Ran **continuously**; during answer recording
  a flag filtered the matcher to accept only `.stop` (it was NOT torn down during TTS — different from today's
  VAD, which is fully torn down around TTS).
- **Why it failed for the Slovak user (root cause, commit message verbatim):** *"English-only voice command
  recognition never worked for the Slovak user."* Two compounding reasons: (1) the model was English-only —
  but the founder now accepts English words, so this reason is retired; (2) **even the English words failed**
  because a Slovak speaker's accented English mis-transcribed ("start"→"stat") and the **exact word-boundary
  match had zero accent tolerance** — a near-miss became a no-match, not a fuzzy hit. **Reason (2) is the live
  one** and dictates the new design.

**Concrete lessons carried into the new design:**
- L1 — **Word choice is the product.** Pick words whose accented pronunciation still transcribes to a
  distinct, matchable token; avoid `th`, avoid vowel-length minimal pairs, avoid words that collapse into each
  other under a Slavic accent (see §B2).
- L2 — **Keep word-boundary tokenization, ADD per-token fuzzy tolerance.** The old exact word-boundary match
  correctly killed the substring false-positive class (keep that) — but it had *no* tolerance for accent
  mis-transcription (fix that). Synthesis: tokenize on word boundaries, then match each token against the
  small **screen-scoped** command set with **phonetic / edit-distance** distance and a confidence floor
  (sibling of the shipped `MCQTranscriptMatcher`). Screen scoping keeps the candidate set to 1–2 words so
  fuzzy margins stay wide.
- L3 — **Contextual biasing was NEVER tried** — the transcriber ran with empty options. It is the single
  biggest unexplored accuracy lever for a fixed small grammar. **BUT** the new `SpeechAnalyzer` framework
  does not expose the custom-vocabulary/`contextualStrings` biasing legacy `SFSpeechRecognizer` had (§B1), so
  this lever is largely unavailable on the locked-in native path — flag as a known loss.
- L4 — **Always keep the visible button.** Voice strictly additive over the existing buttons.
- L5 — **Fold onto the shared-tap topology (77.7); never a third engine.** And critically, do the **cheap
  integration**: `SilenceDetectionService` already instantiates a `SpeechTranscriber` (for the CARQUIZ-3
  pairing) whose `.results` stream is **never consumed** (`SilenceDetectionService.swift:106-113`; only
  `detector.results` is read at `:195`). Adding one async consumer loop on that existing transcriber gives
  English command listening with **no new engine, same tap, same buffers** — the lowest-risk path.
- L6 — **Drop the old TTS-echo overlap heuristic;** window the listener instead (down during TTS), which
  removes self-trigger without the false-negative cost the 60%-overlap hack imposed.

### A2. Current audio topology and where an English command listener fits

*(Full detail in the 2026-07-02 report §A2–A5; delta summary here.)*
- Two model-based systems exist today: `SilenceDetectionService` (`SpeechDetector` VAD, own `AVAudioEngine`
  + tap, iOS 26 only, gated `nil` sub-26) and the ElevenLabs streaming path in `AudioService`
  (`AVAudioEngine` + tap → PCM → `ElevenLabsSTTService.sendAudioChunk`; the STT service owns **no** audio
  hardware). TTS is a downloaded MP3 via `AVPlayer`; **VAD is fully torn down during TTS and re-armed after**
  (time-multiplex, to dodge the `AVAudioEngine`+`AVPlayer` SpeechAnalyzer crash).
- **Where the new English command `SpeechTranscriber` fits (cheapest path):** `SilenceDetectionService`
  already builds a `SpeechAnalyzer(modules: [transcriber, detector])` but **never consumes** the transcriber's
  `.results` (`SilenceDetectionService.swift:106-113`; only `detector.results` at `:195`). Re-configure that
  paired transcriber to an **English** locale (it also satisfies the CARQUIZ-3 pairing) and add one async
  consumer loop → English command listening with **no new engine, same tap, same buffers**. Because START
  stays button/timer, the command listener is **never** live during the ElevenLabs answer stream — the two are
  **time-disjoint**. So the 77.7 pin (one shared `AVAudioEngine` + one
  tap, fanned out) still holds, and the fan-out targets are now: (a) `SpeechDetector` VAD (STOP-on-silence,
  unchanged), (b) ElevenLabs `sendAudioChunk` (answer stream), (c) the **new English command
  `SpeechTranscriber`** — but (b) and (c) never run at the same instant. This is *easier* than the old
  concurrent-with-answer-stream command matching.
- **Self-trigger guard survives:** the command listener must obey the same rule as VAD — **torn down during
  TTS, armed only after TTS completes** (the `1a19438` lesson). An always-on English listener would hear the
  app's own English TTS and self-trigger; windowing prevents it without needing AEC.

### A3. Which screens/states need commands now (button START ⇒ no answer-window commands)

Founder examples: "start", "stop", "restart", "ok". Mapped to `QuizState` / screens (`ContentView.swift`
routing; states from `QuizViewModel.swift`):

| Screen / state | Candidate English command | Maps to existing action |
|---|---|---|
| **HomeView** (`idle`) | **"start"** | begin quiz (start button) |
| **QuestionView** (`askingQuestion`, after TTS) | **"start"** (or "go") → begin recording an answer; **"repeat"** → replay question; **"skip"** → skip | `startRecording()` / `repeatQuestion()` (dead, re-wire) / `skipQuestion()` |
| **QuestionView** (`recording`) | *(none — STOP is automatic on silence; keep it out of the command grammar)* | VAD auto-stop, unchanged |
| **AnswerConfirmationView** (sheet, `processing`) | **"ok"** → confirm; **"again"/"retry"** → re-record | confirm / re-record buttons + 10 s auto-confirm |
| **ResultView** (`showingResult`) | **"next"** (or "ok") → advance | auto-advance / next button |
| CompletionView / Settings / Paywall | *(no voice)* | — |

Notes:
- **"start" replaces the auto-arm.** Because START is now an explicit action, a spoken **"start"** on
  `QuestionView` is the natural hands-free trigger to open the mic — this is the one command that recovers the
  hands-free START the founder wanted, without VAD auto-arm. It is the highest-value command.
- The old plan's **Repeat / Skip / Confirm / Re-record** intents still apply, but now as **English** words
  recognised natively, screen-scoped so context disambiguates (e.g. "ok" = confirm on the sheet, = next on
  the result screen).
- **No command during the recording window** — that window is pure ElevenLabs answer capture; adding English
  command-listening there would fight the answer stream and reintroduce concurrency. STOP stays automatic.

### A4. Pencil design implications (for the planner — do NOT edit `design/quiz-agent.pen` here)

The `.pen` file will need updating to reflect the new voice-command UI. Screens/affordances to add:
- **Listening indicator** — a small "listening for commands" glyph/state on `QuestionView`,
  `AnswerConfirmationView`, and `ResultView` while the English command window is armed (distinct from the
  answer-recording LISTENING card so the driver knows which mode is live).
- **Command hints** — glanceable on-screen hint of the available word(s) per screen (e.g. "Say 'start'",
  "Say 'ok' / 'again'", "Say 'next'"). Replaces the now-false onboarding copy.
- **Home** — a "Say 'start'" affordance for hands-free quiz start.
- **Onboarding** — rework the voice-command explainer screen (current copy "Say 'skip'…" is stale/English-Slovak
  mixed) to teach the small English command set + note it is English-only by design.
- **Earcons are audio, not `.pen`,** but the visual listening indicator should be designed to pair with the
  "mic live" / "command ack" earcons.
- Every voice affordance must have its **button twin visible** (voice is additive) — the design must not imply
  voice-only control.

---

## B. Web pass (cited)

### B1. iOS 26 `SpeechTranscriber` — biasing, grammar, latency, continuous vs windowed

- **No custom-vocabulary / `contextualStrings` on the new framework.** `SpeechAnalyzer`/`SpeechTranscriber`
  does **not** currently expose the custom-vocabulary phrase-biasing that legacy `SFSpeechRecognizer`
  (`SFSpeechRecognitionRequest.contextualStrings`) offered. You receive a plain English transcript and must
  match command words yourself; you **cannot** bias the model toward "restart"/"skip". This is the single most
  important delta fact: accent-robust word choice + fuzzy client-side matching is the *entire* mitigation.
  Sources: Picovoice "iOS Speech Recognition in 2026"
  (https://picovoice.ai/blog/ios-speech-recognition/); Blake Crosley "Speech framework vs SFSpeechRecognizer"
  (https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer).
- **Module choice — `DictationTranscriber` may beat `SpeechTranscriber` for short commands.** iOS 26 ships
  three modules: `SpeechTranscriber` (long-form), `DictationTranscriber` (short-utterance, punctuation), and
  `SpeechDetector` (VAD). For a tiny command grammar, the short-utterance module is the closer fit — the
  planner should A/B both on device. Sources: Anton Gubarenko "iOS 26 SpeechAnalyzer Guide"
  (https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide); Apple WWDC25 session 277
  (https://developer.apple.com/videos/play/wwdc2025/277/).
- **Latency:** ~1.45 s end-of-speech→finalized result even with `prepareToAnalyze` preheat (down from ~2.2 s);
  volatile (partial) results match the final ~95% of the time for short utterances, so drive UI off volatile
  but **act on the final** result. Set the tap to **16 kHz mono** from the start (avoids a resample that adds
  ~200 ms). Sources: DEV "WWDC 2025 — The Next Evolution of Speech-to-Text"
  (https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo);
  callstack "On-Device Speech Transcription with Apple SpeechAnalyzer"
  (https://www.callstack.com/blog/on-device-speech-transcription-with-apple-speechanalyzer).
- **Continuous vs windowed / battery:** `SpeechAnalyzer` removes the old 1-minute session cap, so continuous
  is *possible* — but keeping the ANE warm for low latency trades against power, and a live English listener
  would self-trigger on the app's English TTS. **Recommendation: windowed** — arm only in the command screens,
  tear down otherwise. Same source set as above.

### B2. Non-native (Slovak-accented) English command-word robustness

- Non-native accents raise ASR error rates ~16–20% over native (Stanford, via the accent-robustness
  literature); fixed small-vocabulary command systems are the most sensitive to this because there is no
  language-model context to recover a misheard word. Sources: Springer "Accent-robust speech recognition …
  Manifold Mixup" (https://link.springer.com/article/10.1186/s13636-025-00435-0); "Accent-Invariant ASR via
  Saliency-Driven Spectrogram Masking" (https://arxiv.org/html/2510.09528v1); noise-augmentation for command
  recognition (https://pmc.ncbi.nlm.nih.gov/articles/PMC7219662/).
- **Word-selection heuristics for a Slovak/Slavic accent** (applied prior art from automotive/smart-speaker
  command design + the accent literature):
  - **Avoid `th`** (`/θ/`, `/ð/`) — absent in Slovak, realised as `s`/`t`/`d`/`f`; kills words like "next"…
    actually "next" is fine (no `th`); avoid e.g. "that", "then".
  - **Avoid English vowel-length / lax-tense minimal pairs** ("ship/sheep") — Slovak vowel system differs;
    pick words that don't hinge on a vowel English-natives contrast.
  - **Prefer short, stressed, consonant-anchored, phonetically-distant words** with a Slovak-friendly sound
    inventory. **"stop", "start", "ok", "next"** are strong — all exist as loanwords in Slovak, are pronounced
    near-identically, and are mutually distant. **"restart"** is fine (built from "start"). **"repeat"** and
    **"skip"** are acceptable but weaker (the `sk-`/`sp-` clusters and the `-eat` vowel carry some accent
    risk); "again" is riskier than "retry".
  - **Keep the set tiny and mutually distant** so fuzzy matching has wide margins.
- Additional robustness that costs nothing: match against the transcript with **fuzzy/phonetic distance +
  screen scoping** so a single word only competes against the 1–2 valid commands on that screen.

### B3. Known iOS 26.x regressions relevant to a long-lived transcriber

- **`start(inputSequence:)` streaming failure on 26.3** — a developer reports the streaming (live-mic) path
  fails with `_GenericObjCError` while the offline file path works; affects both `SpeechTranscriber` and
  `DictationTranscriber`. This is the live-mic path the command listener needs — **must be validated on the
  target iOS build on device**, with a defensive fallback to button-only. Source: Apple Developer Forums
  thread 794720 (https://developer.apple.com/forums/thread/794720).
- **Beta "unallocated locales [en_US]" / intermittent transcription crashes** in early iOS 26 betas — locale
  assets must be installed (`AssetInventory.assetInstallationRequest`) before use; handle the
  not-yet-downloaded state. Source: same forum + callstack guide.
- **Simulator gap:** `supportedLocales` returns **empty on the Simulator** and detector/transcriber run only on
  device — so the English command path, like the Slovak VAD, is **not headless-testable end-to-end**; it needs
  a `[HUMAN]` on-device gate. (Carried from the 2026-07-02 report §C1.) This reinforces the CARQUIZ-3-class
  defensive-wrapper requirement: a transcriber setup failure must degrade to button-only, never crash.

---

## C. Build-vs-adopt call (recognizer approach)

Founder has **locked** "native iOS framework, English-only." Working within that:

- **Adopt Apple `SpeechAnalyzer` + (`DictationTranscriber` preferred, `SpeechTranscriber` fallback) for the
  command listener**, English locale, windowed per-screen, fed from the shared tap (77.7). Match command words
  client-side with a fuzzy/phonetic matcher (sibling of `MCQTranscriptMatcher`), screen-scoped, confidence
  floor, diacritic/case fold. Build only: the windowed listener lifecycle, the fuzzy English command matcher,
  the capture-phase/earcon glue, and the defensive fallback.
- **Rejected alternatives (and why):** legacy `SFSpeechRecognizer` (server-backed for many locales, 1-min cap,
  being superseded — worse for driving) — and its only advantage, `contextualStrings` biasing, is real but not
  enough to reverse the founder's "native new framework" lock; **flag it** as the one capability we lose.
  Porcupine custom English wake-word (paid, and unnecessary since English words are accepted). ElevenLabs
  transcript-matching (explicitly reversed by the founder — Slovak transcript, wrong language for English
  commands, and puts commands on the answer hot path).

**Honest risks:**
1. **Accent brittleness is inherent** — the exact thing that killed v1. Mitigated, not eliminated, by word
   choice + fuzzy match + fallback. The `[HUMAN]` device test with the founder's own Slovak-accented English
   is the real acceptance gate; be prepared to swap words after it.
2. **No biasing API** — we cannot tell the model these are the expected words, so a general dictation model may
   transcribe "start" as "star"/"stardt". Fuzzy matching must absorb this; keep the word set small and distant.
3. **iOS point-release fragility** — CARQUIZ-1/-3 precedent + the 26.3 `start(inputSequence:)` report. Defensive
   wrapper degrading to button-only is mandatory.
4. **Self-trigger on English TTS** — windowing (listener down during TTS) is the guard; no AEC needed since
   the listener is never live during TTS.

---

## D. What carries over unchanged from the 2026-07-02 report

- 77.1 (#66 backend early-return guard) and 77.2 (#67-A streaming interruption teardown) — still hard
  prerequisites; unaffected by the recognizer change.
- 77.7 single shared `AVAudioEngine` + one tap — still load-bearing; the fan-out now includes the English
  command `SpeechTranscriber`, but command-listen and answer-stream are **time-disjoint**, so the pin is if
  anything simpler. Re-validated: no third concurrent engine.
- STOP-on-silence stays automatic (`SpeechDetector` + ElevenLabs server VAD); cabin-noise tuning constants
  (hangover 1.2–1.8 s, `.low` sensitivity, min-speech-duration) unchanged.
- The ElevenLabs Scribe v2 Realtime Slovak answer path is untouched (founder-locked as good).
- Earcons (#68 pull-in), the defensive iOS-fragility wrapper, and the CI real-audio blind spot all still apply.
- **Dropped from the old design:** VAD auto-arm START + pre-roll (77.8–77.9) — START is button/timer;
  the Slovak command lexicon + ElevenLabs transcript matching (old 77.3/77.6/77.10) — replaced by native
  English.

---

## Open product questions for the founder (Phase 2)

1. **"start" as the spoken command to open the mic on `QuestionView`** — this is the design's way to recover
   hands-free START without auto-arm. Confirm the founder wants a spoken "start" here (recommended), vs
   button-only START with voice used only for repeat/skip/ok/next.
2. **Final command word set** — recommended tiny set: **start, stop(?), ok, next, repeat, skip** (English,
   accent-chosen). STOP is automatic, so "stop" may be redundant during recording; confirm whether the founder
   wants a spoken "stop" anywhere (e.g. to cancel). Words are provisional pending the on-device accent test.
</content>
</invoke>
