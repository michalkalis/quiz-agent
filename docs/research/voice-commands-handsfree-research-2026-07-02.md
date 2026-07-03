# Research — Re-introducing hands-free voice control (issue #77)

**Date:** 2026-07-02 · **Phase:** 1 (Research) of `/prepare-issue` · **Author:** Claude (Opus)
**Issue:** `docs/issues/issue-77-voice-commands-handsfree.md`

Three strands: (A) local code recon, (B) prior-art scan + build-vs-adopt, (C) cited web research.
The founder explicitly asked for technology + UX research; the web pass RAN because the single most
load-bearing fact — **whether iOS 26 can recognise Slovak on-device** — cannot be answered from the code
and drives the entire design. It can (and did) resolve with citations.

---

## TL;DR (headline findings)

1. **Voice *commands* were already built and deleted.** `VoiceCommandService` (SpeechTranscriber-based
   "repeat/score/help/skip" grammar) shipped Mar 2026, was hardcoded to `en_US`, **never worked for the
   Slovak user**, and was removed wholesale in commit `c7a001c` (2026-04-21). Only the VAD half survives.
2. **iOS 26 on-device speech does NOT support Slovak.** `SpeechTranscriber.supportedLocales` has ~40
   locales — **no `sk`** (no Czech/Polish either). So a re-built on-device Slovak command grammar is a
   dead end for the same reason it failed the first time.
3. **The critical "START" is best solved WITHOUT a spoken keyword.** Use VAD-triggered / auto-armed start
   (the driver just speaks) — language-agnostic, robust, and already ~80% built (`isAutoRecording` +
   `SilenceDetectionService`). This is also the *fewest commands possible* (arguably zero).
4. **"Stop on silence in car noise" is a solved problem, twice over, in the current code.** ElevenLabs
   Scribe v2 Realtime server-side VAD (streaming path) and Apple `SpeechDetector` model-based VAD
   (batch/auto path). Both are model-based (robust in noise) — far better than an RMS energy threshold.
   Recommend **adopt + tune**, not rebuild.
5. **Reversibility: class `a`** — pure iOS feature, no auth/payments/schema/migrations. Backend already
   exposes `/api/v1/elevenlabs/token`; no new server contract needed for the core.

---

# Strand A — Code recon (current state of the voice/audio layer)

All iOS paths relative to `apps/ios-app/Hangs/Hangs/`.

## A1. Voice-command recognition — REMOVED (not disabled)

There is **no** live spoken-keyword recognition today. It was built and then hard-deleted:

- Commit `c7a001c` "refactor(ios): remove voice commands and TTS error announcements" (2026-04-21)
  deleted `VoiceCommandService.swift` (562 lines), `VoiceCommand.swift`, `VoiceCommandIndicator.swift`,
  `QuizViewModel+VoiceCommands.swift`, `VoiceCommandTests.swift`. Commit message, verbatim:
  *"English-only voice command recognition never worked for the Slovak user; auto-submit via silence
  detection and auto-confirm already covered the hands-free use case."*
- `Services/SilenceDetectionService.swift:10-12` doc comment confirms: *"Replaced the former
  VoiceCommandService. We kept only the VAD half — the SpeechTranscriber-based command matching was
  English-only, unreliable for the Slovak user, and duplicated by silence auto-submit + auto-confirm."*
- `SFSpeechRecognizer` was **never** used (zero hits) — the app only ever used the newer `Speech`
  framework `SpeechAnalyzer` family.

**Stale docs to fix as part of #77:** `CONTEXT.md:55-56` ("Repeat/Mute/Skip — always available"),
`Views/OnboardingView.swift:295` ("Say 'skip', 'pass', or 'next' anytime"), `Utilities/Logging.swift:31`
(`Logger.voice` "command recognition") all describe behaviour that no longer exists. `QuizViewModel.repeatQuestion()`
(`QuizViewModel.swift:1017-1024`) is dead code (no callers).

What *survives* from that subsystem, mapped to the canonical commands:
| Command | Reality today |
|---|---|
| Repeat  | Manual button only → `replayQuestionAudio()`; also `ResultView` replay button. |
| Mute    | Settings toggle only (`settings.isMuted`), not spoken. |
| Skip    | Manual button only → `skipQuestion()` (submits literal `"skip"`). |

## A2. What SpeechAnalyzer is used for now — VAD only

`Services/SilenceDetectionService.swift` (`@available(iOS 26, *)`, gated in `AppState.swift:53-57`; on
< iOS 26 the service is `nil` and all VAD/barge-in/auto-record silently no-op):
- Builds `SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)` paired
  with an **unused** `SpeechTranscriber(locale: Locale.current, …)` inside one `SpeechAnalyzer` — the
  transcriber's text is never read; the pairing exists only because **iOS 26.3 requires a detector to be
  paired with a transcriber** (see A6 crash CARQUIZ-3).
- Emits `SilenceEvent.speechStarted` / `.silenceAfterSpeech(duration:)` (silence hangover
  `silenceThreshold = 1.5s`) to auto-stop recording, plus `bargeInEvents` to interrupt TTS.
- Own `AVAudioEngine` + `installTap`; `@preconcurrency import AVFoundation` + `@Sendable` tap to dodge the
  Swift-6 main-thread-assert crash (CARQUIZ-1).

## A3. Answer-recording flow, end to end

**START** (`QuizViewModel+Recording.swift`):
- Manual: `QuestionView` Record button → `toggleRecording()` → `startRecording()` from `.askingQuestion`.
- Auto (hands-free, already built): after TTS finishes, `playQuestionAudio` (`QuizViewModel+Audio.swift:100-106`)
  arms `startThinkingTimeCountdown()` **only if** `settings.autoRecordEnabled && silenceDetectionService != nil`.
  After `settings.thinkingTime` seconds it sets `isAutoRecording = true` and calls `startRecording()`.
- Barge-in (present but **dead** in prod — see #67): `handleBargeIn()` would stop TTS and auto-start
  recording if VAD detects speech during TTS on an external route.

`startRecording()` branches on hardcoded flag `Config.useElevenLabsSTT` (currently **`true`**, verified
`Config.swift:126`):
- **Streaming (default):** `startStreamingRecording()` — fetch single-use token from backend
  (`POST /api/v1/elevenlabs/token`), open WebSocket **directly from iOS** to
  `wss://api.elevenlabs.io/v1/speech-to-text/realtime`, model `scribe_v2_realtime`, PCM 16 kHz mono,
  `commit_strategy=vad`, `vad_silence_threshold_secs=1.5`, `language_code` = session/settings language
  (raw `sk`, not `sk-SK`). Live partials shown in `LiveTranscriptView`.
- **Batch fallback:** `startBatchRecording()` — `AVAudioRecorder` M4A/AAC 16 kHz → `POST` to backend
  ("original Whisper path"). Used if `sttService` nil or streaming setup fails.

**STOP** (four mechanisms, layered):
1. ElevenLabs server VAD → `.committedTranscript` event → `handleCommittedTranscript` (streaming path's
   primary auto-stop).
2. On-device `SpeechDetector` VAD → `.silenceAfterSpeech` → `stopRecordingAndSubmit()` (wired for the
   **batch/auto** path only, not streaming — see comment `QuizViewModel+Recording.swift:119-121`).
3. Hard safety cap: `startAutoStopRecordingTimer` = `Config.autoRecordingDuration` **15 s**.
4. Manual: tap Stop while `.recording`. Plus a 5 s `sttCommitWatchdog` rescue for dead-air on streaming.

**Config constants (verified `Config.swift`):** `autoRecordingDuration=15s`, `sttCommitWatchdogSecs=5s`,
`autoRecordDelayMs=500`, `autoConfirmDelaySecs=10`, `elevenLabsVadSilenceThresholdSecs=1.5`,
`sttStreamingChunkIntervalMs=250`, `thinkingTimeOptions=[0,15,30,45,60,90,120]`.

> **Reconciliation note:** issue-05 (2026-04) temporarily set `useElevenLabsSTT=false` to route Slovak
> through Whisper for quality. Current code has it back to `true` (Scribe v2 Realtime), which matches the
> #77 founder statement that "the ElevenLabs answer-recording flow is good as-is." So Slovak answers
> currently transcribe via ElevenLabs Scribe v2 Realtime, not Whisper.

## A4. Audio session (all in `Services/AudioService.swift`)

- Record+play: `setCategory(.playAndRecord, mode: .spokenAudio, options: […])`. Options per mode include
  `.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP, .duckOthers, .interruptSpokenAudioAndMixWithOthers`.
  **No `.voiceChat` mode, no `setPrefersEchoCancelledInput`, no voice-processing IO** anywhere (grepped).
- Playback-only override `withPlaybackCategory` temporarily switches to `.playback + .spokenAudio` during
  TTS (because `.playAndRecord` attenuates output ~6 dB), restoring in a `defer`.
- Route/interruption observers registered; on interruption `.began` it force-stops recording/playback and
  does **not** auto-resume on `.ended`.
- `.allowBluetoothHFP` is present in every branch on purpose (comment) — without it the BT mic is
  unreachable (A2DP is output-only). This was the #59.3 root cause.

## A5. TTS playback — server-generated, `AVPlayer`

`AVSpeechSynthesizer` was removed in `c7a001c` (zero hits). Question/feedback audio is server-generated
MP3/AAC, downloaded via HTTPS and played through `AVPlayer` (`AudioService.playOpusAudio` — misnamed;
serves MP3, not Opus). **TTS and VAD are time-multiplexed:** silence detection is torn down before TTS
starts and re-armed after, to avoid an `AVAudioEngine`+`AVPlayer` conflict that "crashes SpeechAnalyzer's
RealtimeMessenger." Consequence: true barge-in (speak over the question) is architecturally not possible
today (confirmed by #67 Part B — the `isTTSPlaybackActive` flag is never set `true` in production).

## A6. Crash / stability history baked into this layer

- **CARQUIZ-1** (`abe9189`, 2026-04-18): AVFoundation tap closures aren't `@Sendable`; Swift-6 inserted a
  `dispatch_assert_queue(main)` that fired on the audio thread → crash before closure body ran. Fixed via
  `@preconcurrency import AVFoundation`.
- **CARQUIZ-3** (`b552f24`, 2026-04-28): **iOS 26.3 hardened SpeechAnalyzer** to require SpeechDetector be
  paired with a SpeechTranscriber; a detector-only worker now fatally asserts. This landed *after* commands
  were removed — proof the SpeechAnalyzer contract changed under an iOS point release and broke even
  VAD-only usage. **Design defensively for iOS-point-release drift.**
- **Timer self-trigger** (`1a19438`, 2026-04-15): `thinkingTimeTask` was never assigned so
  `cancelThinkingTime()` was a no-op → recording started during TTS playback (self-trigger). Fixed.

## A7. State machine + screens (the map for voice)

`enum QuizState` (`QuizViewModel.swift:21-96`): `idle · startingQuiz · askingQuestion · recording ·
processing · skipping · showingResult(question,evaluation) · finished · error(message,context)`.
`validTransitions` (`:83-95`) enforced centrally by `transition(to:caller:)` — illegal transitions
rejected + logged + Sentry-tagged. DEBUG-only `"question.state"` probe for UI tests.

Screen routing (`ContentView.swift`):
| State | Screen |
|---|---|
| idle / startingQuiz | HomeView |
| askingQuestion / recording / processing / skipping | QuestionView (mcqBody vs voiceBody) |
| showingResult | ResultView |
| finished | CompletionView |
| error | ErrorView |
Plus: `AnswerConfirmationView` (sheet, auto-confirm 10 s), `LiveTranscriptView` (streaming partials),
`MinimizedQuizView` (floating overlay), Settings/Onboarding/Paywall/AudioDevicePicker.

## A8. Localization / Slovak state (#56)

- `Localizable.xcstrings` — source language `en`, 259 keys, **0 Slovak** entries; project `knownRegions =
  (en, Base)`. Issue-56 built the *English-source* catalog infra; **Slovak UI translation is
  planned/deferred, not started.**
- Two distinct "language" axes: **UI language** (device-locale → catalog; English-only today) vs
  **quiz-content language** (`QuizSettings.language`, e.g. `"sk"`, chosen in Settings; `Language.swift`
  lists `sk` = "Slovenčina"). Default is `"en"`.
- **STT recognition language tracks the quiz-content language** (`QuizViewModel+Recording.swift:87-88` →
  ElevenLabs `language_code=sk`). SpeechAnalyzer's transcriber locale is hardcoded to `Locale.current`
  and its output is unused (VAD-only).

## A9. Earcons / driving-UX (#68) — none implemented

- **Zero** earcon/audio-cue code (`AudioServicesPlaySystemSound`, `SystemSoundID`, beep/chime — all zero
  hits). Only recording-state feedback is haptic (`.sensoryFeedback(.start, …)` in QuestionView).
- #68 (ready-for-agent, unimplemented): 60 s default thinking time (undermines hands-free), no
  record-start/stop earcon (no eyes-free "mic is live" confirmation), orphaned `ImageQuestionView`.

---

# Historical post-mortem — what actually went wrong before

Prioritised by relevance to re-introducing commands. Sources = git history + issue files + memory.

### 1. Root cause of removal — English-only recognition, Slovak user (workaround shipped)
`c7a001c` (2026-04-21): the SpeechTranscriber command grammar was hardcoded `en_US` and **simply never
recognised Slovak speech**. Not a crash — a language-coverage failure. Removed; silence-detection
auto-submit + auto-confirm kept as the hands-free substitute. The underlying Slovak-STT-quality thread is
`issue-05-slovak-transcription.md` (switched to Whisper, later re-enabled ElevenLabs).

### 2. Self-trigger / echo from TTS (fixed)
`1a19438` (2026-04-15): broken cancel of the thinking-time timer let recording start **while the app's own
TTS was still speaking** — the classic self-trigger. Fixed. Lesson for #77: any auto-arm must be strictly
sequenced after TTS completion (or use AEC if simultaneous).

### 3. Crashes on the audio pipeline (fixed, but recurring across iOS versions)
CARQUIZ-1 (Swift-6 tap `@Sendable`), CARQUIZ-3 (iOS 26.3 detector-pairing). Plus two full crash-elimination
waves (2026-04-06/14) for continuation double-resume and `nonisolated(unsafe)` misuse in AudioService.
Lesson: SpeechAnalyzer/AVAudio is fragile under strict concurrency and **point-release API drift**.

### 4. Audio-session conflicts (mixed — two still OPEN)
- **#59.1 / #59.3** (fixed `4eb149d`): TTS silent (missing `setActive(true)`); record broken on AirPods
  (missing `.allowBluetoothHFP` → A2DP-only → BT mic unreachable). Founder-reported on a real Slovak device.
- **#67 OPEN — audio interruption & barge-in:** (A) the `.began` interruption handler calls the *batch*
  `stopRecording()` which bails during streaming → engine keeps sending PCM to ElevenLabs, UI stranded in
  recording after a phone call. (B) barge-in is **structurally dead** (`isTTSPlaybackActive` never set
  true; VAD torn down before TTS). Part B needs a **founder decision**: redesign for mixed audio + AEC, or
  rip out the dead infra.
- **#64 review va#4/#6/#8 (open):** dropped PCM tail-buffer on stop; two concurrent `AVAudioEngine`s
  possible; BT disconnect mid-recording only refreshes device list instead of recovering.

### 5. False-activation / ghost-question (backend, OPEN — #66)
When an utterance parses as a non-answer intent, `flow.py` advances the question and burns a daily-limit
count with no `evaluation` guard; `voice.py` then 400s after the session already moved on. Rated "plausible
in a noisy car." **Directly relevant** — any re-introduced command grammar multiplies false-activation risk.

### 6. Structural test blind spot (repeated finding)
The whole suite mocks `AVAudioSession`/AVFoundation, so **real** audio-session, interruption and Bluetooth
regressions are invisible to CI — RS-01..RS-10 were green while the app was visibly broken (#59). Any #77
work needs at least one on-device/-sim smoke that exercises the real session, or it will regress silently.

---

# Strand B — Prior-art scan & build-vs-adopt calls

## B1. Speech recognition engines (for a Slovak command / answer path)

| Option | Slovak? | On-device? | Verdict for #77 |
|---|---|---|---|
| **Apple `SpeechTranscriber`** (iOS 26) | **No** (`sk` not in supportedLocales) | Yes | ❌ for Slovak commands/answers. ✅ already used as VAD. |
| **Apple `SFSpeechRecognizer`** (legacy) | **Yes, `sk-SK`** — but server-based only (on-device ~10 langs, no Slovak) | Server | ⚠️ network dependency, 1-min cap, being superseded — poor for driving with spotty signal. |
| **Apple `SpeechDetector`** (VAD) | Language-agnostic (acoustic) | Yes | ✅ **adopt** — already the stop-on-silence engine. |
| **ElevenLabs Scribe v2 Realtime** | Yes (90 langs) + built-in VAD | No (WebSocket) | ✅ **keep** — the answer path, per founder. |
| **Porcupine (Picovoice) wake word** | Built-ins: en/fr/de/it/ja/ko/zh/pt/es — **no Slovak**; custom Slovak = contact-sales enterprise | Yes, low-power | ⚠️ only if an explicit Slovak keyword is mandated; adds a paid dep. |
| **Siri / App Intents** | **Siri has no Slovak** | — | ❌ can't drive a Slovak flow. |

## B2. VAD / endpointing (stop-on-silence in car noise)

- **Model-based VAD (Apple `SpeechDetector`, Silero, ElevenLabs server VAD) >> energy/RMS threshold** in
  noise. Silero has ~4× fewer errors than WebRTC VAD at a 5 % false-positive rate; energy thresholds break
  down when the noise floor rises (engine/road noise) — exactly the car-cabin case the founder flagged.
- The app already runs **two** model-based VADs (ElevenLabs server-side; Apple on-device). **Build-vs-adopt:
  ADOPT + TUNE**, do not add Silero unless the built-ins prove insufficient in real car testing. If they
  do, Silero has CoreML/ONNX ports usable on-device.
- Tuning levers: silence hangover (currently 1.5 s both engines — reasonable for driving, longer than
  ChatGPT's 500 ms so it doesn't clip a thinking pause); a **min-speech-duration** and **prefix-padding /
  pre-roll** to (a) reject a cough/road-noise blip as a false start and (b) not clip the first syllable
  when start is VAD-triggered; `SpeechDetector` `sensitivityLevel` (`.medium` now → consider `.low` for
  noise) and ElevenLabs `vadSilenceThresholdSecs` / `minSpeechDurationMs` / `minSilenceDurationMs`.

## B3. Wake-phrase / START command

- **Recommended: no wake phrase.** Make START **VAD-triggered** (arm the mic after the question; the
  first detected speech starts capture, with pre-roll so nothing is clipped). This is language-agnostic
  (works in Slovak with zero ASR), needs no always-on keyword listener (no extra battery, no self-trigger
  from TTS), and reuses `SpeechDetector` already in the app. It's also "the fewest commands possible."
- Always-on keyword spotting (Porcupine/continuous SpeechAnalyzer) costs battery, needs AEC to not
  self-trigger on TTS, and — for Slovak — needs a paid custom model. Reserve for the case the founder
  insists on an explicit spoken keyword (see Product Questions).

## B4. Audio-session coexistence (TTS + mic)

- **Best practice for simultaneous playback + capture (true barge-in): `.playAndRecord` + `.voiceChat`
  mode**, which enables the platform **Voice-Processing IO** (acoustic echo cancellation + AGC + noise
  suppression), so the mic doesn't hear the TTS. Modern alternative: keep the mode but call
  `setPrefersEchoCancelledInput(true)` (iOS 18.2+). Either replaces today's fragile time-multiplex-and-
  pray approach and would make #67 barge-in actually possible.
- **Bluetooth pitfall (the #59.3 family):** any open mic forces BT from A2DP (stereo, hi-fi) to **HFP
  (mono, low-quality)**, degrading both TTS output and mic input — very visible in a car on AirPods/car
  audio. iOS 26 adds a `bluetoothHighQualityRecording` category option to mitigate; evaluate it. Keep
  `.allowBluetoothHFP` (required for the BT mic at all).

---

# Strand C — Outward facts (cited)

## C1. SpeechAnalyzer on iOS 26 + Slovak (LOAD-BEARING)

- **`SpeechTranscriber.supportedLocales` (iOS 26)** = `ar_SA, da_DK, de_AT, de_CH, de_DE, en_AU, en_CA,
  en_GB, en_IE, en_IN, en_NZ, en_SG, en_US, en_ZA, es_CL, es_ES, es_MX, es_US, fi_FI, fr_BE, fr_CA, fr_CH,
  fr_FR, he_IL, it_CH, it_IT, ja_JP, ko_KR, ms_MY, nb_NO, nl_BE, nl_NL, pt_BR, ru_RU, sv_SE, th_TH, tr_TR,
  vi_VN, yue_CN, zh_CN, zh_HK, zh_TW`. **No Slovak, Czech, or Polish.** → on-device Apple transcription of
  Slovak is **not available**. Source: Apple docs + the compiled list —
  https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales ,
  https://developer.apple.com/videos/play/wwdc2025/277/
- **`SFSpeechRecognizer` legacy supportedLocales includes `sk-SK`** (also `cs-CZ`, `pl-PL`, `hu-HU`), but
  Slovak is **server-based only** (on-device set is ~10 languages). Sources:
  https://developer.apple.com/documentation/speech/sfspeechrecognizer/1649889-supportedlocales ,
  https://gist.github.com/bilawal-liaqat/03e3cefa255dca43ea4ae45f527b6ada ,
  https://medium.com/@toru_furuya/available-languages-in-on-device-speech-recognition-on-ios-in-2022-8c6383fac9f2
- **API architecture:** `SpeechAnalyzer` coordinates modules — `SpeechTranscriber` (structured, "short
  commands"), `DictationTranscriber` (free-form + punctuation), `SpeechDetector` (VAD, must be paired with
  a transcriber). Check `supportedLocales` / `installedLocales` and download via
  `AssetInventory.assetInstallationRequest(supporting:).downloadAndInstall()`. Sources:
  https://developer.apple.com/documentation/speech/speechanalyzer ,
  https://developer.apple.com/documentation/speech/speechtranscriber ,
  https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide ,
  https://www.callstack.com/blog/on-device-speech-transcription-with-apple-speechanalyzer
- **Known iOS 26 issues / maturity:** `supportedLocales` returns **empty on the Simulator** (test on
  device); `isAvailable` false on older devices (e.g. iPhone 11 Pro); some reports of
  `start(inputSequence:)` streaming failures where file-based works; ~1.45 s end-of-speech→result latency
  even with `prepareToAnalyze`. Use `volatileResults` for UI, act on finalized results. Sources:
  https://dev.to/arshtechpro/wwdc-2025-the-next-evolution-of-speech-to-text-using-speechanalyzer-6lo ,
  https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer ,
  https://developer.apple.com/forums/thread/794720

## C2. Silence-detection endpointing in noise

- **Production voice apps stop on server VAD keyed to a silence duration.** OpenAI Realtime `server_vad`
  defaults: `threshold≈0.5`, `prefix_padding_ms=300`, `silence_duration_ms=500`; a higher threshold
  "might perform better in noisy environments"; there's also a **semantic VAD** that decides turn-end from
  words, not just silence. Source: https://developers.openai.com/api/docs/guides/realtime-vad
- **ChatGPT Advanced Voice** uses this server_vad silence-duration mechanism — and its known failure mode
  is cutting users off on short pauses when the threshold is too tight, i.e. **too-aggressive endpointing
  is the risk**, argues for a longer hangover while driving. Sources:
  https://sites.duke.edu/ddmc/2026/04/22/be-quiet-chatgpt-will-not-shut-up/ ,
  https://livekit.com/blog/turn-detection-voice-agents-vad-endpointing-model-based-detection (notes an
  "800 ms silence timeout adds nearly a full second to every response"; Silero VAD "more robust against
  background noise and short pauses" than simple silence detection).
- **Silero VAD in noise:** ~4× fewer errors than WebRTC at 5 % FPR; adjust probability threshold per
  environment and use a **hangover** to avoid chopping words. Sources:
  https://picovoice.ai/blog/best-voice-activity-detection-vad/ ,
  https://aiadoptionagency.com/silero-vad-voice-activity-detection/ ,
  https://arxiv.org/pdf/2312.05815 (VAD in noisy environments)
- **ElevenLabs Scribe v2 Realtime** does its own VAD-based auto-commit: `vadSilenceThresholdSecs` (example
  1.5), `minSpeechDurationMs`, `minSilenceDurationMs`; manual vs VAD commit strategy; 90 languages, PCM
  8–48 kHz, ~150 ms latency. Sources:
  https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime ,
  https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies ,
  https://elevenlabs.io/blog/how-scribe-v2-realtime-works
- **Apple `SpeechDetector`** reports speech start/end but "cannot run alone; must be paired with a
  transcriber," and is "not a standalone VAD engine." Sources:
  https://www.callstack.com/blog/on-device-speech-transcription-with-apple-speechanalyzer ,
  https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer

## C3. Voice UX for driving / minimal command set

- **Fixed-grammar vs natural:** Apple's own guidance contrasts **Voice Control** (fixed commands, "may
  fail at the slightest variation") with **Siri** (tolerates phrasing). A re-built fixed Slovak grammar
  inherits the brittleness that already sank v1. **Eyes-free** is the design goal (Siri Eyes Free:
  control without looking/touching). Sources: https://support.apple.com/guide/iphone/use-siri-in-your-car-iph0aa8c80e6/ios ,
  https://www.apple.com/ios/carplay/ , https://www.idownloadblog.com/2026/03/10/voice-control-carplay/
- **Confirmation without looking:** the app has none (haptic-only). Driving voice UX needs **earcons** — a
  distinct "mic is now live" tone at START and a "got it" tone at STOP — so the driver never looks down.
  This is exactly issue-68's open earcon item; #77 should pull it in or hard-depend on it.
- **GPT-style recording UI** (the founder's optional polish): ChatGPT/Gemini voice mode use an animated
  orb/waveform with clear listening/thinking/speaking states. Maps onto `LiveTranscriptView` + a state
  indicator; candidate for the **separate UI-polish issue** the founder allowed.

## C4. Audio-session coexistence (TTS + STT)

- **`.playAndRecord` + `.voiceChat` enables platform AEC/AGC/noise-suppression (Voice-Processing IO)** —
  the recognised way to run TTS and mic together without self-trigger. `setPrefersEchoCancelledInput(true)`
  is the newer per-input toggle. Sources:
  https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat ,
  https://developer.apple.com/documentation/avfaudio/avaudiosession/setprefersechocancelledinput(_:)
- **Bluetooth HFP/A2DP:** "whenever any audio input is active, Bluetooth must switch to HFP" — A2DP is
  output-only and can't do duplex, so opening the mic drops BT to mono low-quality HFP. iOS 26 adds
  `bluetoothHighQualityRecording`. Sources:
  https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp ,
  https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording ,
  https://medium.com/@mehsamadi/understanding-avaudiosession-routes-on-ios-7718d934d0c0

---

# Synthesis — recommendations for the plan (not the final plan)

## Technology decisions the research supports

1. **Do NOT rebuild a Slovak on-device command grammar.** On-device Apple can't do Slovak; the last
   English grammar failed the Slovak user. (C1, post-mortem #1.)
2. **Make START hands-free via VAD-triggered / auto-armed capture, not a spoken keyword.** Reuse
   `SpeechDetector` + `isAutoRecording`; add pre-roll so the first word isn't clipped. Language-agnostic,
   robust, fewest commands. (B3.)
3. **Keep STOP = automatic model-based VAD; adopt + tune, don't rebuild.** Prefer the on-device
   `SpeechDetector` for the START trigger and (for the streaming answer) ElevenLabs server VAD; tune
   hangover (~1.2–1.8 s), add min-speech-duration + prefix-padding for car-noise robustness; consider
   `SpeechDetector` `.low` sensitivity. Silero only as a fallback if built-ins fail on-road. (B2, C2.)
4. **Keep the ElevenLabs Scribe v2 Realtime answer flow** (founder-locked; already `useElevenLabsSTT=true`).
5. **If simultaneous TTS+mic / barge-in is wanted, move to `.playAndRecord`+`.voiceChat` (or
   `setPrefersEchoCancelledInput`) for AEC** — resolves #67 Part B properly instead of the time-multiplex
   hack. Otherwise keep strict sequencing (TTS → then arm mic) to avoid self-trigger. (B4, C4.)
6. **Add earcons (#68) — a "mic live" and a "got it" tone.** Eyes-free confirmation is non-negotiable for a
   driving command UX. (C3.)
7. **Design defensively for iOS point-release drift** (CARQUIZ-3 precedent) and **add a real-audio-session
   smoke test** to close the CI blind spot that hid #59. (Post-mortem #3, #6.)

## Candidate minimal command-set + screen/state map

Honest recommendation given the Slovak constraint: **near-zero spoken commands; hands-free via VAD +
glanceable buttons + safe auto-advance.**

| Where (QuizState / screen) | Hands-free behaviour | Mechanism |
|---|---|---|
| askingQuestion — TTS reads Q (QuestionView) | (optional) **barge-in**: driver starts talking to answer immediately | VAD during TTS + AEC (needs B4/#67) |
| askingQuestion — after TTS / thinking window | **auto-arm mic**; earcon "mic live" | `isAutoRecording` + earcon |
| **START answering (critical)** | driver just speaks → capture begins | **VAD-triggered start** (SpeechDetector), pre-roll buffer |
| recording (LISTENING card + live transcript) | speak the answer | ElevenLabs streaming STT |
| **STOP answering (critical)** | stop on silence; earcon "got it" | VAD silence (server + on-device), 15 s hard cap |
| processing (AnswerConfirmationView) | auto-confirm after 10 s (already built) | timer |
| showingResult (ResultView) → next | auto-advance; TTS reads result | timers/#68 defaults |
| Repeat / Skip / Next / Confirm / Re-record | **large glanceable buttons + auto defaults**, NOT spoken (Slovak recognition unreliable) | UI + timers |

Explicit spoken commands beyond "just talk to answer" are **deferred/optional** pending the product
decision below; if required, scope them as a small English keyword set or a paid Slovak Porcupine model,
clearly flagged as added cost/risk.

## Build-vs-adopt (one line)

**Adopt + tune** what's already in the app (Apple `SpeechDetector` VAD, ElevenLabs Scribe v2 Realtime,
`isAutoRecording`) and **do not rebuild** any Slovak command recognizer or energy-threshold VAD; the only
genuinely new build is the VAD-triggered start with pre-roll + earcons (+ optionally the `.voiceChat`/AEC
audio-session upgrade to enable barge-in).

## Reversibility

**Class `a`** — pure iOS feature. No auth, payments, DB schema, or migrations. Backend already exposes the
ElevenLabs token endpoint; no new server contract for the core. The optional AEC/audio-session change is
iOS-local and revertible. (The only non-`a`-flavoured risk is the recurring platform-fragility of
SpeechAnalyzer across iOS point releases — a robustness concern, not an irreversibility one.)

## Open PRODUCT questions (for the founder — cannot be settled by research)

1. **Explicit spoken START vs implicit VAD start.** The founder named "START recording an answer" as *the*
   command, but for Slovak the robust, simple, zero-ASR solution is **implicit** (auto-arm + the driver
   just speaks). Does the founder want (A) an explicit spoken keyword — which for Slovak needs a paid
   custom wake-word model or an English loanword, both with cost/robustness tradeoffs — or (B) implicit
   VAD/auto-record start (recommended)? This decision shapes the whole issue.
2. **Barge-in (interrupt the question while it's being read).** Worth building (needs the `.voiceChat`/AEC
   audio-session redesign, reopens #67 Part B) or explicitly out of scope / rip out the dead infra?
3. **Secondary commands (Repeat / Skip / Next).** Accept "glanceable buttons + auto-advance" for these
   (recommended, given Slovak ASR limits), or does the founder specifically want them spoken too?
4. **GPT-style recording UI polish** — spin into a separate issue (founder said agent's call): recommend
   **yes, separate**, so #77 stays a focused control-mechanism issue.
