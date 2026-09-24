# Noise suppression vs. car Bluetooth output — research 2026-09-24

**Trigger:** #185 car test 2026-09-23 (TF build with #184 voice processing ON, Media Mode). Output moved from the car's Bluetooth A2DP to the iPhone speaker whenever the mic engine armed voice processing (VPIO). Call Mode (HFP, car mic) keeps VPIO but the founder rated the call-quality audio as very bad. Goal: keep noise suppression if at all possible, find the compromise.
**Related:** [issue #184 batch STT in car noise](../issues/issue-184-batch-stt-car-noise.md) · [STT car-noise research 09-21](stt-car-noise-research-2026-09-21.md) · [#185 car-test diagnosis](../design/variants/issue-185-car-test-2026-09-23.md) · `Utilities/VoiceProcessingPolicy.swift` · `Services/AudioService.swift` (`categoryOptions`, `quizSessionConfiguration`).

## TL;DR

- **Apple voice processing and A2DP output cannot coexist through any public API** (as of iOS 26.5). This follows from Apple's documented mode behavior (below). No iOS 17, 18 or 26 API changes that.
- **The "keep NS + car speakers" compromise exists only in software:** no VPIO, plain mic tap, plus our own processing (a high-pass filter and level normalization, optionally a neural denoiser) on the audio that feeds the VAD and command recognizer. Whether denoising also helps Scribe is **unproven, and recent literature says it often hurts** modern ASR. Measure before shipping it on the STT path.
- VPIO did **not** fix the real car blocker: in the 09-23 drive, with VP ON, `SpeechDetector` missed speech in 16/16 answers (5 s timeout every time). The VAD problem is separate from VP.

## 1. The VPIO ⇄ A2DP conflict: what is documented

| Claim | Status | Source |
|---|---|---|
| Using the voice-processing I/O unit without a chat mode makes the session **implicitly switch to `.voiceChat`** (unless `.videoChat`/`.gameChat` was already set). Our `.spokenAudio` is therefore overridden the moment VP is armed. | **Documented** (Apple, `voiceChat` and `videoChat` pages) | [1], [2] |
| `.voiceChat`/`.videoChat` "reduce the set of allowed audio routes to only those suitable for voice/video chat" and auto-apply `.allowBluetoothHFP`. A2DP is output-only, so it cannot be a duplex chat route. | Documented (route reduction); A2DP's exclusion is inferred, not spelled out | [1], [3] |
| With A2DP excluded and HFP not in our Media Mode options, the route falls back to the receiver, and `.defaultToSpeaker` turns that into the **iPhone speaker**. That matches what the founder saw. | Inferred from [1]+[4]; consistent with the 09-23 observation. It is still **unverified on device** why we did not land on HFP, since voiceChat "auto-applies" it. | [1], [4] |
| `setVoiceProcessingEnabled` on either I/O node enables VP on both. Input and output are one VP unit, so no "VP on input only". | Documented (header) | [5] |
| Forum reports: A2DP output collapses to speaker in `.playAndRecord` on iOS 17+ in some setups (AirPods Pro 2, USB input); VPIO with mismatched in/out devices fails to build its aggregate device (macOS). None has a DTS answer. | Anecdotal | [6], [7], [8] |

**Depends on:** mode (every chat mode behaves the same, and `.default`/`.spokenAudio` are overridden by VPIO), and VPIO itself. It does **not** depend on `.defaultToSpeaker`: that option only picks speaker over receiver for the fallback, and removing it would put the audio on the earpiece. iOS version: the docs text predates iOS 17, and nothing in iOS 17–26 relaxes it.

**iOS 17–26 APIs checked (SDK 26.5 headers), none gives VP + A2DP:**
- `voiceProcessingOtherAudioDuckingConfiguration` (iOS 17) only changes how other apps' audio is ducked. It has no effect on routing [5], [9].
- `.bluetoothHighQualityRecording` (iOS 26) gives full-band **Bluetooth mic** input on "certain AirPods models". It works **only in `.default` mode**, is "not currently supported in the European Union" (the founder is in Slovakia), adds input latency, and nothing documents car head-unit support [10], [11]. **Not applicable.**
- `.farFieldInput` (iOS 26.2) **requires HFP** and a BT mic that reports `farFieldCapture.isSupported`. Car support is unknown. Same call-audio problem [11].
- `setPrefersEchoCancelledInput` (iOS 18.2) is AEC only (no NS). It works only for the built-in mic plus **built-in speaker**, only in `.playAndRecord`+`.default`, and only on 2024+ iPhones [11]. It does not help a car speaker.
- Mic Modes (Voice Isolation) are user-selected in Control Center, and historically apply only to apps using the VoiceIO unit [12], [13]. So they have the same route conflict. iOS 26 extends Voice Isolation to "certain third-party recording apps" [13], but the opt-in mechanism is **undocumented (unverified)**.

## 2. Noise suppression without VPIO (A2DP output + built-in mic stay intact)

| Option | What it is | Route impact | Cost / latency | Evidence it helps our STT |
|---|---|---|---|---|
| **HPF (~100–150 Hz) + level normalization** in the existing tap | Deterministic DSP (`AVAudioUnitEQ` high-pass or a vDSP biquad; peak/RMS normalize the WAV) | none | ~0 CPU, ~0 ms | Removes engine/road rumble below the voice band and restores level that AGC used to provide. Low risk for Scribe; the main target is the VAD. Unmeasured |
| **AUSoundIsolation** (`kAudioUnitSubType_AUSoundIsolation`, `'vois'`) | Apple's on-device neural voice isolation. **Public constant** in AudioToolbox since iOS 16, with `HighQualityVoice` added in iOS 18. Effect AU usable via `AVAudioUnitEffect`. Also on macOS 13+, so the exported WAVs can be tested **offline on the Mac** | none | no dependency; realtime CPU, latency and required sample rate **undocumented (unverified)**; Apple ships it in Music Sing on iPhone 11+ [14], [15] | none published for ASR |
| **DeepFilterNet3** (CoreML ~2.2 MB) / **RNNoise** | OSS neural denoisers, 48 kHz. DFN is higher quality at ~30–40 ms. RNNoise is tiny at ~10 ms and weak on non-stationary noise | none | new SPM dependency; runs on the 48 kHz mic before downsampling | none for Slovak ASR [16], [17] |
| **ElevenLabs Voice Isolator API** before Scribe | Server-side isolation (`pcm_s16le_16` input supported) | none | **$0.12/min**, which is **~$0.01 per 5 s answer, ~17× the whole ~$0.0006/answer cost model**, plus one extra round trip (latency unpublished) [18], [19] | none published |
| **Scribe v2 batch alone** (today) | The model's own noise robustness | none | $0.22/h | AA-WER 2.2 %, sk FLEURS 3.4 % (vendor) [see 09-21 research] |

**Important caveat:** a systematic 2025 study found that speech-enhancement preprocessing *raised* WER for Whisper, Parakeet and Gemini in **all 40** noise × model configurations (+1.1 % to +46 %) [20]. Similar results hold for source separation before Whisper [21]. Google's STT guidance also says not to apply noise reduction [22]. Modern large ASR models are trained on noisy audio, so denoising artifacts hurt them more than the noise does. **Implication:** the on-device denoiser belongs on the **VAD and command-recognizer feed**, where the small Apple models need it most. Send Scribe the raw (HPF-plus-normalized) WAV unless offline WER shows otherwise.

## 3. Do we even need echo cancellation?

- **Answer recording: no.** Answers are captured after TTS ends, behind a post-TTS gate, so no own-audio echo is in the clip. In the car, VPIO's value for answers was only **NS + AGC** (plus undocumented multi-mic beamforming, which is **unverified**).
- **Barge-in during TTS: this is the one place AEC would matter.** `SilenceDetectionService` fires barge-in when `SpeechDetector` hears speech while TTS plays on an **external** route. But VPIO can never run on the A2DP route anyway, so this path has always worked without AEC in the car (pre-#184 and after #173). The risk of self-trigger from car-speaker TTS is unchanged. Mitigate by requiring a matched command (not bare VAD) during TTS if it shows up in the logs.
- Other apps' music in the car: VPIO's AEC reference for other apps' audio is undocumented, and Apple ducks it instead [9]. So AEC would not reliably remove Spotify from the mic either.

**Conclusion:** giving up VPIO on the car route loses NS + AGC, not AEC. Both can be approximated in software without touching the route.

## 4. Test matrix for the next drive

**Principle:** record **raw audio in the car once** and test every denoise variant **offline** on the same WAVs. Only VP on/off and the route need the car. Same driver, phone mount and route; alternate blocks of 8–10 answers; log speed (city ≤50 / highway ≥100 km/h) and whether music was playing.

| Cell | Route (output / input) | VP | Answers | Answers the question |
|---|---|---|---|---|
| **A** | Car BT A2DP / iPhone mic (Media Mode) | off | 25 | the proposed default |
| **B** | iPhone speaker, BT off / iPhone mic | on | 12 | what VPIO buys ... |
| **C** | iPhone speaker, BT off / iPhone mic | off | 12 | ... B vs C isolates VP (same mic, same position) |
| D (optional) | Car HFP (Call Mode) | on | 8 | only if the founder wants to re-check the car mic |

**Offline arms over A and C** (`scripts/stt_compare.py` plus a preprocessing step): `raw` · `hpf+norm` · `AUSoundIsolation` (macOS harness) · `DeepFilterNet3` (Python `deepfilternet`) · `ElevenLabs isolator` (~50 × 5 s ≈ 4 min ≈ $0.50, under the spend threshold). Each arm is sent to **Scribe v2** and **gpt-transcribe**.

**Metrics**

1. **WER/CER** per arm against `<stamp>.ref.txt`. Report the median and the share of exact-match answers, since single-word answers make WER coarse.
2. **VAD onset hit rate:** the share of clips *not* ending at the 5.0 s no-speech timeout (`durationMs` in the sidecar). On 09-23 it was 0/16 with VP on.
3. **End-of-speech lag:** `durationMs` minus the annotated speech end (hand-mark it in the WAV or estimate with offline Silero).
4. **Offline VAD replay:** run the same WAVs through `SpeechDetector` (Speech framework on macOS 26, **unverified that it runs identically there**) and Silero at the current `.low` and a higher sensitivity, with and without `hpf+norm` / isolation. This separates the "VAD is deaf" bug from the "noise" question.
5. **Route sanity:** every clip's `inputPort` **and output port**. The sidecar has no output port today, so add it, and also log `session.mode` after VP arm to confirm the implicit `.voiceChat` switch.
6. Commands: the hit rate on a scripted list ("ďalej", "znova", "preskoč", "ok") per cell. This needs #185 item 3.5 (command text logging) first.

**Decision rule:** if B beats C by less than about 5 pp CER and `hpf+norm` or a denoiser on A closes the VAD gap, ship A-style as the default. If B beats C clearly, keep VP for phone-speaker use and invest in on-device denoise for the car.

## 5. Ranked recommendation

1. **Route-aware VP (do now):** arm VP only when the output route is the built-in speaker (phone-only use) or HFP (Call Mode). Keep it off whenever the output is A2DP, BLE, car audio, AirPlay or wired. This keeps the car speakers with no call UI. It is option A of the #185 diagnosis. Fix the stale comment in `VoiceProcessingPolicy.swift` too: `.spokenAudio` does **not** survive VPIO (see [1]).
2. **HPF + level normalization in the mic tap (do now, cheap):** software stand-in for VPIO's AGC and the low-frequency part of its NS, with no new dependency. Apply it to the VAD/command feed and to the uploaded WAV.
3. **Fix the VAD independently:** raise `SpeechDetector` sensitivity, or fall back to Silero (FluidAudio) per the 09-21 research. This is the actual blocker, and VP did not solve it.
4. **Evaluate on-device neural isolation offline first:** AUSoundIsolation (zero dependency) before DeepFilterNet3. Adopt it **only on the VAD/command feed** if it measurably helps detection. Keep Scribe on raw audio unless offline WER proves a gain [20].
5. **ElevenLabs Voice Isolator:** offline experiment arm only. In production it would multiply the per-answer cost by ~17× and add a round trip.
6. **Keep Call Mode (HFP + VP) as an opt-in**, as today. The iOS 26 Bluetooth high-quality recording and far-field options do not rescue it for cars in the EU.
7. **Rejected:** toggling VP around each recording. Every toggle re-routes the whole system output (other apps' music too), costs an A2DP renegotiation, and repeats the #173 volume jump. This is option C of the #185 diagnosis.

**Is there a "keep noise suppression + car speakers" compromise?** Not with Apple's voice processing. **Yes with software suppression** (items 2 and 4) on a plain mic tap, which leaves the A2DP route untouched. Its STT benefit is unproven and possibly negative, and its VAD benefit is plausible. The drive in §4 decides.

## Sources

1. Apple, `AVAudioSession.Mode.voiceChat`: https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat
2. Apple, `AVAudioSession.Mode.videoChat`: https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/videochat
3. Apple, `allowBluetoothA2DP` (A2DP = output-only; HFP wins on a shared device): https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetootha2dp
4. Apple, `defaultToSpeaker`: https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/defaulttospeaker
5. Apple, `AVAudioIONode.setVoiceProcessingEnabled(_:)` header discussion (iPhoneOS 26.5 SDK, `AVAudioIONode.h`): https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)
6. Apple Dev Forums 745993, A2DP output falls to speaker, iOS 17, AirPods Pro 2 (no reply): https://developer.apple.com/forums/thread/745993
7. Apple Dev Forums 737904, `allowBluetoothA2DP` ignored in playAndRecord, iOS 17: https://developer.apple.com/forums/thread/737904
8. Apple Dev Forums 810129, VP fails with mismatched in/out devices: https://developer.apple.com/forums/thread/810129
9. WWDC23 10235, What's new in voice processing (other-audio ducking): https://developer.apple.com/videos/play/wwdc2023/10235
10. WWDC25 251, Enhance your app's audio recording capabilities (AirPods HQ recording): https://developer.apple.com/videos/play/wwdc2025/251/
11. Apple, `bluetoothHighQualityRecording` (mode `.default` only, not in EU) + SDK 26.5 `AVAudioSessionTypes.h` / `AVAudioSession.h` (`FarFieldInput`, `setPrefersEchoCancelledInput`): https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording
12. Apple Dev Forums 690152, Mic Mode requires the AUVoiceIO unit (community, no DTS): https://developer.apple.com/forums/thread/690152
13. Apple Support 101993, Mic Modes (iOS 26: recording apps): https://support.apple.com/en-us/101993
14. Apple, `kAudioUnitSubType_AUSoundIsolation` (+ `AudioUnitParameters.h`, SDK 26.5): https://developer.apple.com/documentation/audiotoolbox/kaudiounitsubtype_ausoundisolation
15. QuietNow, AUSoundIsolation in practice (iPhone 11+/A13): https://github.com/spotlightishere/QuietNow
16. DeepFilterNet2 paper (real-time embedded): https://arxiv.org/pdf/2205.05474 · CoreML port: https://github.com/kylehowells/DeepFilterNet-mlx
17. Fora Soft, Krisp vs RNNoise vs DeepFilterNet latency (engineering blog): https://www.forasoft.com/learn/ai-for-video-engineering/articles-ai/real-time-noise-suppression-krisp-rnnoise-deepfilternet
18. ElevenLabs API pricing (Voice Isolator $0.12/min, Scribe v2 $0.22/h): https://elevenlabs.io/pricing/api
19. ElevenLabs Audio Isolation API: https://elevenlabs.io/docs/api-reference/audio-isolation/convert
20. "When De-noising Hurts" (arXiv 2512.17562): https://arxiv.org/abs/2512.17562
21. "When Audio Separation Hurts Zero-Shot ASR" (arXiv 2603.04710): https://arxiv.org/html/2603.04710v2
22. Google Cloud STT, audio best practices (no noise reduction): https://docs.cloud.google.com/speech-to-text/docs/v1/best-practices-provide-speech-data
