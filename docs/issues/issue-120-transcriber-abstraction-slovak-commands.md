# #120 — Transcriber abstraction + Slovak voice commands

**Triage:** implemented 2026-07-26 (agent work done, all suites green) · open = founder car legs + engine decision · class b · Fable 5, effort high
**Depends on:** #119 — Voice-command recognition quality (landed `a12eba9`…`c64209c`, `4d98e11`)
**Related:** #77 — Voice commands hands-free (locked "English-only commands" as decision P2 — **this issue reopens that decision, founder-approved 2026-07-26**)

---

## Goal

Make the two Apple on-device transcribers — `SpeechTranscriber` and `DictationTranscriber` — interchangeable behind one seam we own, so their recognition quality can be compared on the same audio, on the same trip, with the same telemetry. Add Slovak as a second command language, which only `DictationTranscriber` can serve.

Nothing above the seam may know or care which engine is running. `VoiceCommandCoordinator`, the matcher, the lexicon and the UI must be unchanged in their contract: they keep consuming `AsyncStream<CommandTranscript>` and keep working if the engine is swapped at launch.

## Why this, why now

#119 fixed three real causes of "it understands me very badly" (no `.fastResults` → ~4 s of silence from the transcriber; no echo cancellation/AGC on the mic; the window stayed open during the app's own speech). Those are landed and a founder car leg is pending. This issue is the **next lever if that is not enough**, and it is the only lever that changes the recognizer itself rather than the plumbing around it.

`DictationTranscriber` is attractive for three independent reasons, not just Slovak:

1. **It honors `AnalysisContext.contextualStrings`; `SpeechTranscriber` ignores them** (Apple DTS, forum thread 801877). Our command vocabulary is seven fixed words. Being able to hand the recognizer that list is a structurally better fit than our current defence, which is hand-written spelling variants plus edit-distance matching.
2. **It exposes `ContentHint.farField` and `ContentHint.atypicalSpeech`** — a car cabin and a strong non-native accent, named almost verbatim. `SpeechTranscriber` has no equivalent.
3. **It has a `.phrase` preset**, designed for exactly our shape of input, where `SpeechTranscriber`'s presets are all transcription-shaped.

`SpeechTranscriber` keeps one real advantage: Apple positions it as the newer, more accurate base model, and it is the one we have field telemetry for. Hence a comparison rather than a migration.

## Measured facts — do not re-derive these

Queried directly against the iOS 26.5 SDK and the macOS 26.5.2 runtime on 2026-07-26 (see #119 §"Locale support — measured"):

| | `SpeechTranscriber` | `DictationTranscriber` |
|---|---|---|
| `supportedLocales` | 30 — zero Slavic, no `sk_SK` | 54 — includes `sk_SK`, `cs_CZ`, `pl_PL` |
| `sk_SK` on-device asset | n/a | **exists** — `assetInstallationRequest` returns a real download request, so Slovak works offline after a one-time install |
| `contextualStrings` | ignored | honored |
| `ReportingOption` | `.volatileResults` `.alternativeTranscriptions` **`.fastResults`** | `.volatileResults` `.alternativeTranscriptions` **`.frequentFinalization`** |
| Presets | transcription-shaped | **`.phrase`**, `.shortDictation`, progressive variants |
| `ContentHint` | none | `.shortForm` `.farField` `.atypicalSpeech` `.customizedLanguage` |

Both conform to Apple's `SpeechModule` + `LocaleDependentSpeechModule`, and both `Result` types carry `text: AttributedString` and inherit `isFinal` from `SpeechModuleResult`. `SpeechAnalyzer(modules:)` already takes `[any SpeechModule]`. So the shapes line up; what does *not* line up is configuration (different `Preset`, different `ReportingOption`, different `ContentHint`), and `SpeechModule` carries associatedtypes, so its `results` stream cannot be consumed through a bare existential.

**Trap:** `supportedLocale(equivalentTo:)` returns `sk_SK` for *both* classes, including the one that does not support it — it normalizes an identifier rather than testing membership. `SilenceDetectionService.swift:263` correctly gates on `supportedLocales.contains`; keep it that way for both engines.

## The hard unknown — measure it, do not assume it

**`DictationTranscriber` has no `.fastResults`.** That option was the single biggest win in #119: without it the transcriber emitted nothing for ~4 s, which mechanically explained 37 of 56 command windows seeing zero transcripts at a ~1.3 s median window lifetime. Its nearest analogue here is `.frequentFinalization`, whose semantics are finalization cadence, not first-hypothesis latency.

So the central risk is that `DictationTranscriber` recognizes better but **too late to fire inside a command window**, which would make it useless for us no matter how accurate it is. Treat first-hypothesis latency as the primary comparison metric alongside accuracy, and land the instrumentation that measures it before tuning anything. #119 measured `SpeechTranscriber` at volatile-first 4211 ms without `.fastResults` and 1155 ms with it — reuse that harness and that baseline.

## Constraints

**Architecture.** The seam belongs *inside* `SilenceDetectionService`, not above it. `SilenceDetectionServiceProtocol` (`SilenceDetectionService.swift:74-111`) already hides the recognizer from the whole app and is what the entire test suite mocks; do not disturb it. What is missing is one level down: `SilenceDetectionService+Engine.swift:30-37,115` constructs `SpeechTranscriber` inline. That construction, its configuration, and the normalization of its `Result` into our `CommandTranscript` are what needs to become an adapter with two implementations. Prefer two concrete adapters each owning their concrete transcriber over any attempt to genericize across Apple's associatedtypes.

**Capability asymmetry must be explicit, not averaged.** Vocabulary biasing, content hints and the reporting options exist on one engine and not the other. Model that as a capability the adapter declares, so the service can feed the lexicon to whichever engine accepts it and skip it for the one that ignores it. Do not invent a lowest-common-denominator config that silently drops `.fastResults` from the `SpeechTranscriber` path — that would re-break #119.

**Engine selection.** Launch-time, DEBUG-and-TestFlight reachable, defaulting to today's behaviour (`SpeechTranscriber`, English) so a bad build cannot regress prod. Follow the existing precedent — `AppState.swift:81-98` gates `--ui-test-voice-ready` behind `#if DEBUG` and swaps the service via DI. A founder-facing toggle is required, because the comparison has to be runnable on a real drive, not just in tests; a hidden settings row is acceptable, a recompile is not.

**Telemetry must be comparable or the whole issue is pointless.** Every existing voice hot-path event must carry the same engine tag and the same locale tag, so a Sentry query can slice #119's recall and precision metrics by engine. The emission points are enumerated across `SilenceDetectionService.swift`, `+Engine.swift`, `VoiceCommandCoordinator+Listening.swift`, `+Routing.swift`, `+Utterance.swift` and today each builds a bare `[String: Any]` literal with no shared builder. Add first-hypothesis latency to that set. Metric names must not change — the 2026-07-24 and 2026-07-26 baselines have to stay comparable.

**Slovak needs a Slovak lexicon, and that is the risky half.** `VoiceCommandLexicon.swift:69-85` is English-only by design and its header says so. Recognizing Slovak audio without Slovak phrases yields nothing, so the lexicon has to become locale-scoped.

The second-order problem matters more than the translation: **in English-only mode the command vocabulary is disjoint from what the user actually says in the car; in Slovak mode it is not.** The user speaks Slovak continuously on a road trip, so a Slovak command set will false-fire in a way the English one structurally cannot. `VoiceCommandLexicon.swift:83` already records this hazard — the Slovak discourse particle "no" was deliberately kept out of `.stop`. Choose Slovak phrases for *disjointness from ordinary Slovak conversation*, prefer multi-syllable and imperative forms over short particles, and treat precision as ranking above recall for the Slovak set. Destructive commands must stay final-only per #119. Flag any phrase you keep despite a collision risk rather than quietly shipping it.

A starting set to critique, not to accept: štart · ďalej · zopakuj · preskoč · znova · stop. `ok`/`dobre`/`áno` are the obvious precision hazards — `áno` and `dobre` occur constantly in normal speech. Recommend a set with reasons; the founder decides the final wording.

**Do not regress #119.** The volatile-result path is load-bearing and subtle: at-most-one-fire-per-utterance latch, settle gate, one-content-token cap, destructive commands final-only, window closed during feedback TTS, voice-processing (echo cancellation / AGC / noise suppression) enabled on the input node, and the 8 kHz Bluetooth HFP path that is silently accepted and degrades quietly. All of that lives above or beside the seam and must survive both engines. `CommandListenerTests.swift` and `VoiceCommandObservabilityTests.swift` pin much of it — they must stay green without being weakened.

**Repo rules.** Files ≤ ~300 lines; `SilenceDetectionService.swift` (380) and `+Engine.swift` (369) already exceed it, so extracting the adapter should reduce them, not add a third oversized file. No `nonisolated(unsafe)` — `@MainActor` or `OSAllocatedUnfairLock`. Test targets are Swift 6 strict with MainActor-default. Conventional Commits, scope `ios`. Commit at every natural checkpoint and push without asking.

**Simulator reality.** `SpeechTranscriber` cannot run on the Simulator at all — empty `installedLocales`, `SFSpeechErrorDomain` Code=1 — which is why the entire suite mocks at the `SilenceDetectionServiceProtocol` level and no test has ever instantiated a real transcriber. Check early whether `DictationTranscriber` is any better there, since it reuses the system dictation model; if it runs, that is a genuine testability win worth exploiting. If it does not, say so plainly and keep the adapter's own unit tests at the normalization/configuration level rather than faking a working recognizer.

## Done means

- Both engines selectable at launch, default unchanged, app code above the seam untouched in contract.
- Slovak and English both reachable on `DictationTranscriber`; English still on `SpeechTranscriber`; locale gated on `supportedLocales.contains` for both, with the existing fail-loud degrade to buttons when a locale or asset is unavailable, and the Slovak asset download surfaced through the existing `.installingAssets` state rather than a new mechanism.
- Every voice hot-path event carries engine + locale; first-hypothesis latency is measured and emitted; existing metric names unchanged.
- Adapter and lexicon covered by tests; `CommandListenerTests` / `VoiceCommandObservabilityTests` / `VoiceCommandMatcherTests` green and not weakened; full HangsTests green apart from the documented pre-existing allowances (the `NetworkServiceTests`/`PackOrderServiceTests` URLProtocol pair and the `EntitlementReconcileTests` usage-retry timing flakes, all green in isolation — do not try to fix those here).
- A TestFlight build the founder can drive with, plus a written statement in this file of exactly which Sentry query compares the two engines, and which numbers would settle the choice.

## Explicitly out of scope

The MCQ spoken-answer path (`MCQTranscriptMatcher.swift`) — different matcher, different audio path, already Slovak-aware via `QuizSettings.language`. The onboarding copy at `OnboardingView.swift:296` ("Commands are spoken in English by design, even when the app is in Slovak") becomes wrong the moment Slovak commands ship — update that one string, but do not redesign onboarding. The red iOS CI usage-retry flakes. Any `SFSpeechRecognizer` fallback.

## Founder decisions already locked

- Slovak commands are wanted; #77's "English-only for all users" (decision P2) is **superseded** for this issue.
- Both engines ship behind a switch; this is a comparison, not a migration. No engine is removed until a car leg says which wins.
- Final Slovak wording is the founder's call — bring a recommendation with collision reasoning, do not just translate.

---

## Implemented 2026-07-26

- **Seam:** `CommandTranscriberAdapter` (Services/) — two concrete adapters, each owning its transcriber's construction, config and `Result`→`CommandTranscript` normalization. SpeechTranscriber config is bit-identical to #119 (`.volatileResults`+`.fastResults`); DictationTranscriber runs `.volatileResults`+`.frequentFinalization`, hints `.shortForm`+`.farField`, and gets the command vocabulary via `AnalysisContext.contextualStrings` (capability declared as presence/absence — `nil` on the engine that ignores it). `SilenceDetectionServiceProtocol` untouched; every consumer above the seam unchanged.
- **Selection:** `CommandEngineSelection` (Utilities/) — 3 valid cases only (`speech-en` default, `dictation-en`, `dictation-sk`), UserDefaults-backed, launch snapshot; release-visible "Command engine" menu row in Settings → voice (flags "restart app" until relaunch). Unrecognized stored value falls back to today's engine.
- **Lexicon/matcher:** language-scoped with a default arg = launch selection, so all call sites and pre-#120 tests are unchanged. Slovak set below. Onboarding "English, always" copy updated.
- **Telemetry:** every `.voice` SentryLog event now carries `engine` + `cmdLocale`, injected centrally in `SentryLog` from `VoiceTelemetryContext` (stamped once by the service; code above the seam stays engine-blind). No metric renamed. New `firstHypothesisMs` attribute on `voice transcriber result`: ms from VAD speech-start (engine-independent anchor) to the engine's first result, one-shot per utterance.
- **Tests:** `TranscriberEngineTests.swift` (18 tests: selection mapping/persistence, adapter capability asymmetry + concrete modules, Slovak recall/precision/strict-skip/volatile-floor, latency anchor with fake clock). Full HangsTests **778/778 green** (5 `.dump` snapshots re-recorded — diff was exactly the service's three new stored properties; onboarding copy assert updated to the new string).

**Simulator reality (measured on iOS 26.5 sim):** `DictationTranscriber.supportedLocales` = 54 incl. `sk_SK`, `installedLocales` = 1 — unlike SpeechTranscriber (empty, `SFSpeechErrorDomain 1`). So the dictation engine at least passes the locale gate on the Simulator; whether it actually transcribes there is unverified, and the mock-at-protocol test strategy stays. Probe test `simulatorLocaleProbe` prints the counts on every run.

### Slovak command set (recommendation — founder confirms wording)

Matcher variants (normalized): štart→`start` · potvrď/ok/okej→`.ok` · ďalej/pokračuj→`.next` · znova/znovu→`.again` · zopakuj/opakuj→`.repeatQuestion` · preskoč/vynechaj→`.skip` (strict) · stop/zruš→`.stop`. Backchannels **áno · dobre · hej · jasné · no · tak** are deliberately FILLER — they can never fire a command (saying "áno" will not confirm; say "potvrď" or "ok"). Flagged residual hazards, kept knowingly: **"ok"/"okej"** occur in conversation (bounded: final-only on the confirmation sheet, benign on result); lone **"ďalej?"** as a conversational "go on" can advance the result screen (benign — auto-advance was coming); **"stoj"** scores 0.75 vs "stop" (rare, final-only, confirmation-only). Dropped as too hot: bare "no" (per existing lexicon note), "áno"/"dobre" as confirm words.

### The Sentry queries that settle the engine choice

All voice events now carry `engine` (`speech`|`dictation`) and `cmdLocale`. Compare per drive (one engine per drive, flipped in Settings + relaunch):

1. **Latency (primary):** `message:"voice transcriber result" has:firstHypothesisMs` → p50/p95 of `firstHypothesisMs` grouped by `engine`. Baseline: SpeechTranscriber ≈1155 ms (off-device #119 measurement; confirm on-device). **Decision rule: if dictation p50 > ~1.3 s (the median command-window lifetime from build-33), dictation is unusable regardless of accuracy.**
2. **Recall proxy:** count of `voice cmd matched` ÷ count of `voice cmd consumer started`, by `engine`; plus `voice cmd consumer exited` with `transcriptsSeen=0` rate (the #119 zero-transcript symptom).
3. **Precision proxy:** `voice cmd suppressed` reason distribution by `engine`, plus the `beginSkipUndoWindow`→abort rate and any `voice cmd matched` with no intended command (founder feedback leg).
4. **Slovak leg:** same queries with `cmdLocale:sk_SK`; extra attention to false fires (query 3) — the Slovak set's structural risk.

**Winner =** engine with p50 `firstHypothesisMs` ≤ ~1.3 s AND equal-or-better matched-rate AND no worse suppression/false-fire profile over at least one full drive each. If both pass latency, prefer the one with fewer `unmatched` finals on real command words (founder narrates which words he said).
