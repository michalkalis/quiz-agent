# #119 — Voice-command recognition quality ("it understands me very badly")

**Triage:** DONE (agent side) — awaiting founder car leg
**Priority:** P0 (hands-free is the product)
**Filed:** 2026-07-26, founder report after driving build 33
**Predecessor:** the stream-plumbing P0 fixed in `92688fe` (see [issue-105](issue-105-voice-commands-dead.md)) — commands now fire, this issue is about them being usable.

## The report, and why it was the wrong knob

> "voice commandy uz obcas funguju ale je problem, ze mi velmi zle rozumie. bolo by potrebne nejak zmiernit nejaky threshold porozumienia."

The founder asked to LOWER the confidence threshold. Field telemetry from build 33 (2026-07-24, real device, 5 sessions, 31 transcriber results) says that would have made things worse, and the evidence is unambiguous enough that **it must not be re-chased**:

| Floor | Unmatched field transcripts rescued |
|-------|-------------------------------------|
| 0.72 (shipped) | 0 of 20 |
| 0.65 | 0 |
| 0.60 | 0 |
| 0.55 | 0 |
| 0.50 | 5 — all false positives that fire real actions |

Best score any of the 20 unmatched transcripts reaches against its own screen's commands is **0.50** — an empty dead zone below the floor. The five "rescued" at 0.50 are `"lobster the last name"` → start, `"he is proud of you"` → ok, `"oh great"` → ok. Two land on screens where `ok` advances the quiz.

**The accent theory is also refuted.** Every dropped transcript containing a real command word is letter-perfect — verbatim `"start start start start start"` and `"start start start start start start start"`. Not one of the hand-written accent-mangled variants (`stat`, `sart`, `shtart`, `strt`) appears anywhere in 24 captured transcripts: an en-US language model snaps output to dictionary words, not phonetic spellings. The variant tables were the wrong shape and were deleted.

Field split: 7 matched · 20 unmatched (overwhelmingly conversational speech and backchannels the matcher correctly rejected) · 4 dropped with the window closed, **3 of which were perfect "start"**. Commands `next`, `repeat`, `skip`, `again`, `stop` had never matched once.

## Actual root causes

**1. The transcriber emits NOTHING until ~4 s of audio.** Empirical probe of the shipped configuration (`scratchpad/volatile_probe.swift`, macOS 26.5, same Speech.framework, 12 runs / 8 utterances): with finals-only, one word plus silence gives volatile at 4211 ms and final at 4275 ms — the whole burst in one ~70 ms clump, nothing before. That is the transcriber's default context window, not compute (a 33-result sentence completed in 418 ms when fed at 30×).

Consequences: (a) waiting for the end-of-speech endpoint meant each repeat EXTENDED the segment and pushed finalization further out — the vicious cycle behind the 7× "start"; (b) **any listening window shorter than ~4 s yields nothing at all**, which mechanically explains the field data — median command-window lifetime ~1.3 s, and 37 of 56 consumer exits saw ZERO transcripts.

`.fastResults` moves the first hypothesis to 1155 ms (final 2288 ms). Apple's `Preset.progressiveTranscription` — "configuration for immediate transcription of live audio" — *is* `volatileResults + fastResults`. The SDK doc string calls it "less accurate"; measurement beat the doc string, and the accuracy cost is bounded here by a seven-word fixed vocabulary behind 0.72/0.85 floors with destructive commands waiting for a final.

**2. The mic was unprocessed.** `setVoiceProcessingEnabled` appeared nowhere in the target — no echo cancellation, no AGC, no noise suppression, in a moving car.

**3. The window stayed open during feedback TTS.** `isPlayingQuestionTTS` covered only question TTS, so `QuizViewModel.handleAnswerResponse` armed the window and then played feedback underneath a live input tap. The app was transcribing itself: `"you said proud answer proud"`, `"he is proud of you"`.

## What shipped

| Area | Change |
|---|---|
| Recognizer | `reportingOptions: [.volatileResults, .fastResults]`; volatile hypotheses forwarded alongside finals as `CommandTranscript{text, isFinal}` |
| Mic | `setVoiceProcessingEnabled(true)` + least-aggressive other-audio ducking (music must not duck) + one-shot retry with VP disarmed if `engine.start()` fails; `AVAudioConverter` re-feed bug fixed |
| Window | closes during **all** TTS, not just question TTS; the async re-arm re-validates after it suspends so a parked `startListening()` cannot outlive the stop that raced it |
| Volatile safety | at most ONE command per utterance; destructive commands (`skip`, `again`, `stop`, and `ok` on the confirmation sheet) require a FINAL; ~350 ms settle gate before a volatile may fire; 1.5 s per-command cooldown |
| Precision | content-token cap of 1 DISTINCT non-filler token; bare `"no"` removed from `.stop` variants (high-frequency Slovak discourse particle) but KEPT on the fail-safe undo-cancel path; `"nx"` removed from `.next`; speculative accent spellings deleted |
| Feedback | haptics alongside the earcons — the cues play via `AudioServicesPlaySystemSound` on the ringer route and are plausibly inaudible in a car, which is what the 2.5 s skip undo relies on |
| Telemetry | audio route / input sample rate / voice-processing state at listener start; `sincePrevMs`, `path=` (final · volatile-repeat · volatile-settle) and suppression counters — the first false-fire proxies, since a true and a false fire logged identically before |

**Result:** benign commands fire ~0.8 s after the word (first hypothesis ~0.45 s + 0.35 s settle) instead of ~2.3 s; destructive ones deliberately still wait ~1.6–2.3 s.

Commits `a12eba9` · `cb3afd6` · `5068b03` · `c95b5c3` · `a2fa2c1` · `e76aadf` · `c64209c`. Full suite green (760 tests / 143 suites). 5 `.stableDump` baselines re-recorded — state-shape churn only, no UI text or structure change; flagged for human sign-off per `.claude/rules/ios.md`.

## Corrected false premise

`VoiceCommandLexicon`'s header asserted that SpeechAnalyzer has no vocabulary biasing, and that claim was the stated justification for the entire hand-written-variants design. **It is wrong.** `AnalysisContext.contextualStrings` and `SpeechAnalyzer.setContext(_:)` exist in the iPhoneOS 26 SDK; the accurate narrower statement is that `SpeechTranscriber` ignores them while `DictationTranscriber` honors them.

That makes `DictationTranscriber` the escape hatch if this round is not enough: it supports contextual-string biasing, `ContentHint.atypicalSpeech` (documented verbatim for "a speaker with a heavy accent"), `.farField` for a car mic, a weighted custom language model, and **sk-SK** — `SpeechTranscriber` supports zero Slavic locales. The trade is that Apple positions `SpeechTranscriber` as the newer, more accurate base model. The cheap decisive experiment is to run BOTH modules in the same analyzer and log which one the matcher resolves correctly.

## Verification — the only gate that matters

All probe numbers are macOS, not iPhone; `SpeechTranscriber` cannot run on the Simulator at all (`SFSpeechErrorDomain` Code=1, empty `installedLocales`). One founder car leg on the TestFlight build (production, uploaded 2026-07-26, run `30204383282`), then compare Sentry against the 2026-07-24 baseline:

**Recall:** transcripts dropped with window closed (was 4/31) · consumer exits with `transcriptsSeen == 0` (was 37/56) · matched vs unmatched (was 7/20) · whether `next`/`repeat`/`skip`/`again`/`stop` ever match at all (all five were at zero — if they still are, the problem is neither the matcher nor the audio).

**Precision — define the abort threshold before the leg, because a false fire and a true fire are otherwise indistinguishable:** `abortSkipUndoWindow` vs `beginSkipUndoWindow` ratio · `again`/`stop` firing within seconds of the confirmation sheet appearing · matched commands per question (~1 expected, >2 is a misfire signature) · the suppression counters.

**Config confirmation:** the `voice command listener started` log must show voice processing actually enabled and a 16 kHz built-in mic — `availableCompatibleAudioFormats` is [8000, 16000], so an 8 kHz Bluetooth HFP path is silently ACCEPTED and degrades quietly.

**Tuning:** `sincePrevMs` p95 is what replaces the 0.35 s settle guess.

## Deliberate trades the founder should know about

1. On the result screen a spoken command does not work **while the feedback is being read** (~3–5 s of the auto-advance window). It works before and after. This is the price of the app not transcribing itself; the alternative is trusting echo cancellation over the car's A2DP route, which is unverified.
2. `"no"` no longer means "stop" — it is one of the highest-frequency Slovak discourse particles and the mic is open with passengers present. It still aborts a pending skip, where aborting is the fail-safe direction.
3. Recall narrowed deliberately: one-edit near-misses (`"nekst"`, `"skib"`) no longer match, and `"stat"` matches only on a final. Backed by the field evidence that real command words transcribe perfectly — but worth watching in the next session's data.

## Rejected, with reasons (do not re-litigate)

- **Lowering `confidenceFloor`** — the founder's literal ask. See the table above; offline sweep agrees (every floor 0.85→0.50 is dominated on F1; 0.50 collapses precision to 61%).
- **Lowering `skipFloor`** — inert under the shipped algorithm; loosening a destructive command's floor for no measured gain is pure downside.
- **Tuning `ambiguityMargin`** — provably a no-op: every value 0.00–0.30 gives byte-identical results, because within each screen's 1–3 commands the words are lexically far apart.
- **Phonetic matching (Double Metaphone / Soundex)** — measured WORSE than plain Levenshtein (F1 0.707 / 0.725 vs 0.772); it collapses `store`~`star` and `can`~`gain`.
- **Prefix containment and adjacent-token bigram joins** — short variants become wildcard prefixes over whole word families (`no`→now/note/noise, `stat`→station/statue, `ski`→skiing/skid on the DESTRUCTIVE command).
- **`.alternativeTranscriptions` (N-best)** — the primary transcript is already letter-perfect for real command words; N-best would only widen the false-fire surface.
- **`AVAudioSession` mode `.voiceChat`** — automatically applies `allowBluetoothHFP`, which would force the car's 8 kHz mic and re-break the deliberate [#104](issue-104-car-audio-session-call-mode.md) Media Mode design. `.measurement` minimizes signal processing — wrong direction for a cabin.
- **Switching locale to en-GB / en-IN** — no Apple-published per-locale accuracy data; the general ASR literature contradicts itself. Trivially A/B-able on device later; does not belong in a plan as a fix.
- **`SpeechTranscriber.supportedLocale(equivalentTo:)` as a capability check** — a trap: it returns non-nil for sk-SK even though sk-SK is absent from `supportedLocales`. The existing membership check in `prepareAssets()` is correct; do not let anyone "simplify" it.
- **Raising VAD sensitivity `.low` → `.medium`** — `.low` was A/B'd against real cabin noise at 77.15, and voice processing changes the acoustics; re-tuning it blind in the same batch would make the car leg uninterpretable.

## Known residuals

- `SilenceDetectionService+Engine.swift` (358) and `VoiceCommandCoordinator+Utterance.swift` (354) are over the ~300-line cap. Both were already over before the last edits; next clean boundaries are the protocol/event declarations and the `#105` authorization block.
- The temporary raw-transcript logging (`"text"` attribute) still must be removed before GA — tracked in `docs/todo/TODO.md`. It is now gated on `voiceCommandsEnabled`, so a founder who turns commands off uploads nothing.
- The `.fastResults` accuracy trade is argued, not measured — the probe measured latency only. The suppression counters are what would detect a regression.
