//
//  SilenceDetectionServiceTests.swift
//  HangsTests
//
//  Unit tests for the three-state machine inside SilenceDetectionService:
//    idle → speechActive → silenceAccumulating(since:) → emits silenceAfterSpeech
//
//  Strategy: inject a FakeClock via the `now:` seam (Task 1.6).  Drive the state
//  machine by calling `handleSpeechDetectorResult(speechDetected:)` directly —
//  no AVAudioEngine / SpeechAnalyzer touched.
//
//  Event collection: the test calls `collectSilenceEvents(from:driving:)`, which:
//    1. Starts a collector task on `@MainActor`.
//    2. Calls the user-supplied `driving` closure (synchronously on @MainActor).
//    3. Finishes the `silenceEvents` stream by deallocating the service (the
//       `deinit` calls `silenceChannel.finish()`).  This terminates the
//       `for await` loop inside the collector.
//    4. Awaits the collector's value to get the complete event list.
//  Because finishing the stream is the only reliable termination signal, the
//  service is created *inside* `collectSilenceEvents`.
//
//  Availability: SilenceDetectionService is @available(iOS 26, *).  Swift Testing
//  macros (@Suite / @Test) do not support @available on struct/func level, so we
//  guard with `#available` inside each test body and return early via
//  `withKnownIssue` when running on iOS < 26.
//

//  MARK: - Out of scope

//  • Barge-in path (`setTTSPlaybackActive` + `isExternalAudioRoute`) —
//    depends on `AVAudioSession.sharedInstance()` which is not stubbable
//    without a full audio session mock. Coverage deferred.
//  • `startListening()` / `stopListening()` — require real AVAudioEngine +
//    SpeechAnalyzer. Out of scope for this task.
//

import AVFoundation
import Foundation
@testable import Hangs
import Speech
import Testing

// MARK: - FakeClock

@MainActor
private final class FakeClock {
    var now: Date

    init(start: Date = Date(timeIntervalSince1970: 0)) {
        now = start
    }

    func advance(_ seconds: TimeInterval) {
        now.addTimeInterval(seconds)
    }
}

// MARK: - Collection helper

/// Creates a `SilenceDetectionService` with an injected `FakeClock`, runs the
/// `driving` closure (which drives `handleSpeechDetectorResult` calls), then
/// destroys the service (triggering `deinit` → `silenceChannel.finish()`)
/// and awaits the collector task to get the complete event list.
///
/// The two-step approach (drive → finish → await) is necessary because
/// `AsyncStream` is a pull-based producer: the collector Task runs on
/// `@MainActor` interleaved with the test, and the only reliable way to know
/// all events have been drained is to wait for the stream to finish.
@available(iOS 26, *)
@MainActor
private func collectSilenceEvents(
    driving: @MainActor (SilenceDetectionService, FakeClock) -> Void
) async -> [SilenceEvent] {
    let clock = FakeClock()

    // Wrap in Optional so we can nil it out (triggering deinit) on demand.
    var service: SilenceDetectionService? = SilenceDetectionService(now: { clock.now })

    // Capture the stream before the service might be deallocated.
    let stream = service!.makeSilenceEventStream()

    // Start the collector task BEFORE driving any state changes.
    let collector = Task { @MainActor in
        var collected: [SilenceEvent] = []
        for await event in stream {
            collected.append(event)
        }
        return collected
    }

    // Drive state machine changes.
    driving(service!, clock)

    // Deallocate the service → deinit calls silenceChannel.finish() →
    // the `for await` loop in the collector task terminates naturally.
    service = nil

    // Now await the collector; it will return as soon as the stream is done.
    return await collector.value
}

// MARK: - SilenceDetectionServiceTests

@Suite("SilenceDetectionService — state machine")
@MainActor
struct SilenceDetectionServiceTests {
    // MARK: 1. Initial state is idle

    @Test("silence while idle emits no event")
    func silenceWhileIdleEmitsNothing() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, _ in
            service.handleSpeechDetectorResult(speechDetected: false)
        }
        #expect(events.isEmpty)
    }

    // MARK: 2. idle → speechActive emits .speechStarted

    @Test("speechDetected true while idle emits .speechStarted")
    func idleToSpeechActiveEmitsSpeechStarted() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, _ in
            service.handleSpeechDetectorResult(speechDetected: true)
        }
        #expect(events == [.speechStarted])
    }

    // MARK: 3. speechActive is idempotent — repeated true yields no extra events

    @Test("repeated speechDetected true while speechActive emits no additional event")
    func speechActiveIsIdempotent() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, _ in
            service.handleSpeechDetectorResult(speechDetected: true) // idle → speechActive
            service.handleSpeechDetectorResult(speechDetected: true) // no-op
            service.handleSpeechDetectorResult(speechDetected: true) // no-op
        }
        #expect(events == [.speechStarted])
    }

    // MARK: 4. speechActive → silenceAccumulating emits no event

    @Test("speechDetected false while speechActive emits no event")
    func speechActiveToSilenceAccumulatingEmitsNothing() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, _ in
            service.handleSpeechDetectorResult(speechDetected: true) // idle → speechActive (.speechStarted)
            service.handleSpeechDetectorResult(speechDetected: false) // speechActive → silenceAccumulating (no event)
        }
        // Only the initial .speechStarted — no event for entering silenceAccumulating
        #expect(events == [.speechStarted])
    }

    // MARK: 5. silenceAccumulating → speechActive (resume) — no extra .speechStarted

    @Test("speech resuming from silenceAccumulating returns to speechActive without new .speechStarted")
    func resumeFromSilenceAccumulatingNoExtraSpeechStarted() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, _ in
            service.handleSpeechDetectorResult(speechDetected: true) // idle → speechActive
            service.handleSpeechDetectorResult(speechDetected: false) // speechActive → silenceAccumulating
            service.handleSpeechDetectorResult(speechDetected: true) // silenceAccumulating → speechActive
        }
        // Only the original .speechStarted — no second one on resuming from silenceAccumulating
        #expect(events == [.speechStarted])
    }

    // MARK: 6. Threshold boundary: 1.4 s — NOT emitted

    @Test("silence of 1.4 s does NOT cross the 1.5 s threshold")
    func silenceAt1_4sNotEmitted() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, clock in
            service.handleSpeechDetectorResult(speechDetected: true) // idle → speechActive
            service.handleSpeechDetectorResult(speechDetected: false) // speechActive → silenceAccumulating(since: t0)
            clock.advance(1.4)
            service.handleSpeechDetectorResult(speechDetected: false) // still below threshold
        }
        let silenceAfterEvents = events.filter {
            if case .silenceAfterSpeech = $0 { return true }; return false
        }
        #expect(silenceAfterEvents.isEmpty, "Expected no silenceAfterSpeech at 1.4 s, got \(silenceAfterEvents)")
    }

    // MARK: 7. Threshold boundary: 1.5 s exactly emits

    @Test("silence of exactly 1.5 s emits silenceAfterSpeech(duration: ~1.5)")
    func silenceAt1_5sEmits() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, clock in
            service.handleSpeechDetectorResult(speechDetected: true) // idle → speechActive
            clock.advance(0.5) // real utterance (> min-speech guard, 77.11)
            service.handleSpeechDetectorResult(speechDetected: false) // → silenceAccumulating(since: t0)
            clock.advance(1.5)
            service.handleSpeechDetectorResult(speechDetected: false) // → emits + idle
        }
        let durations = events.compactMap { event -> TimeInterval? in
            if case let .silenceAfterSpeech(d) = event { return d }; return nil
        }
        guard let duration = durations.first else {
            Issue.record("Expected .silenceAfterSpeech event, got \(events)")
            return
        }
        // 1.5 = 3/2 is exact in IEEE 754; 1e-9 is sufficient, but use 1e-6 to match
        // other duration assertions in this file.
        #expect(abs(duration - 1.5) < 1e-6, "Expected duration ~1.5, got \(duration)")
    }

    // MARK: 8. Threshold boundary: 1.6 s emits

    @Test("silence of 1.6 s emits silenceAfterSpeech(duration: ~1.6)")
    func silenceAt1_6sEmits() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, clock in
            service.handleSpeechDetectorResult(speechDetected: true)
            clock.advance(0.5) // real utterance (> min-speech guard, 77.11)
            service.handleSpeechDetectorResult(speechDetected: false)
            clock.advance(1.6)
            service.handleSpeechDetectorResult(speechDetected: false)
        }
        let durations = events.compactMap { event -> TimeInterval? in
            if case let .silenceAfterSpeech(d) = event { return d }; return nil
        }
        guard let duration = durations.first else {
            Issue.record("Expected .silenceAfterSpeech event, got \(events)")
            return
        }
        // TimeInterval is Double; addTimeInterval with 1.6 accumulates ~2.4e-8 error
        // (1.6 is not exactly representable in IEEE 754). Use 1e-6 (microsecond) tolerance.
        #expect(abs(duration - 1.6) < 1e-6, "Expected duration ~1.6, got \(duration)")
    }

    // MARK: 9. After threshold, state returns to idle

    @Test("after threshold emit, further silence yields no event; fresh speech yields .speechStarted again")
    func afterThresholdStateReturnsToIdle() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, clock in
            // Full cycle: speech → silence threshold → idle
            service.handleSpeechDetectorResult(speechDetected: true)
            clock.advance(0.5) // real utterance (> min-speech guard, 77.11)
            service.handleSpeechDetectorResult(speechDetected: false)
            clock.advance(1.5)
            service.handleSpeechDetectorResult(speechDetected: false) // emits → idle

            // Silence while back in idle — should emit nothing
            service.handleSpeechDetectorResult(speechDetected: false)

            // Fresh speech from idle should emit .speechStarted again
            service.handleSpeechDetectorResult(speechDetected: true)
        }

        let speechStartedCount = events.filter { $0 == .speechStarted }.count
        let silenceAfterCount = events.filter {
            if case .silenceAfterSpeech = $0 { return true }; return false
        }.count

        #expect(speechStartedCount == 2, "Expected 2 .speechStarted events, got \(speechStartedCount)")
        #expect(silenceAfterCount == 1, "Expected 1 .silenceAfterSpeech event, got \(silenceAfterCount)")
    }

    // MARK: 10. Multiple speech-silence cycles

    @Test("two complete speech-silence cycles emit two .speechStarted and two .silenceAfterSpeech in order")
    func multipleSpeechSilenceCycles() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let events = await collectSilenceEvents { service, clock in
            // Cycle 1
            service.handleSpeechDetectorResult(speechDetected: true) // .speechStarted
            clock.advance(0.5) // real utterance (> min-speech guard, 77.11)
            service.handleSpeechDetectorResult(speechDetected: false) // accumulating at t0
            clock.advance(1.5)
            service.handleSpeechDetectorResult(speechDetected: false) // .silenceAfterSpeech(~1.5) → idle

            // Cycle 2
            service.handleSpeechDetectorResult(speechDetected: true) // .speechStarted
            clock.advance(0.5) // real utterance (> min-speech guard, 77.11)
            service.handleSpeechDetectorResult(speechDetected: false) // accumulating at t1
            clock.advance(2.0)
            service.handleSpeechDetectorResult(speechDetected: false) // .silenceAfterSpeech(~2.0) → idle
        }

        let speechStartedCount = events.filter { $0 == .speechStarted }.count
        let durations = events.compactMap { event -> TimeInterval? in
            if case let .silenceAfterSpeech(d) = event { return d }; return nil
        }

        #expect(speechStartedCount == 2, "Expected 2 .speechStarted events, got \(speechStartedCount)")
        #expect(durations.count == 2, "Expected 2 .silenceAfterSpeech events, got \(durations.count)")

        if durations.count == 2 {
            // Use 1e-6 (microsecond) tolerance — TimeInterval is Double and
            // addTimeInterval accumulates small representability errors.
            #expect(abs(durations[0] - 1.5) < 1e-6, "First silence duration ~1.5, got \(durations[0])")
            #expect(abs(durations[1] - 2.0) < 1e-6, "Second silence duration ~2.0, got \(durations[1])")
        }

        // Assert ordering: speechStarted, silenceAfterSpeech, speechStarted, silenceAfterSpeech
        guard events.count == 4 else {
            Issue.record("Expected exactly 4 events, got \(events.count): \(events)")
            return
        }
        #expect(events[0] == .speechStarted)
        if case .silenceAfterSpeech = events[1] { } else {
            Issue.record("Expected events[1] to be .silenceAfterSpeech, got \(events[1])")
        }
        #expect(events[2] == .speechStarted)
        if case .silenceAfterSpeech = events[3] { } else {
            Issue.record("Expected events[3] to be .silenceAfterSpeech, got \(events[3])")
        }
    }
}

// MARK: - VoiceCommandAvailabilityTests (#77 device fix — fail-loud plumbing)

/// WHY: on device, voice commands silently never worked — every setup failure
/// (missing model assets, analyzer.start throw, nil format) was swallowed.
/// These tests pin the fail-loud contract: the flag starts `.unknown`, every
/// failure path routes through `markCommandsUnavailable` and becomes visible,
/// and the launch-time `prepareAssets()` always resolves to a terminal state.
/// Real recognition is NOT testable on the simulator (supportedLocales is
/// empty there) — device verification is gate 77.15.
@Suite("SilenceDetectionService — command availability (fail-loud)")
@MainActor
struct VoiceCommandAvailabilityTests {
    @Test("availability starts .unknown before prepareAssets resolves")
    func initialAvailabilityIsUnknown() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let service = SilenceDetectionService()
        #expect(service.commandAvailability == .unknown)
    }

    @Test("markCommandsUnavailable (the seam every failure path uses) flips the flag with its reason")
    func markUnavailableSetsFlagWithReason() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let service = SilenceDetectionService()
        service.markCommandsUnavailable(reason: "SpeechAnalyzer start failed: boom")
        #expect(service.commandAvailability == .unavailable(reason: "SpeechAnalyzer start failed: boom"))
    }

    @Test("prepareAssets resolves to a terminal state — never left .unknown")
    func prepareAssetsResolvesTerminalState() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let service = SilenceDetectionService()
        await service.prepareAssets()
        // On the simulator supportedLocales is empty → .unavailable; on a device
        // with assets it would be .ready. Either way it must not stay .unknown —
        // a hung/unset flag would reproduce the silent-failure bug.
        #expect(service.commandAvailability != .unknown)
    }

    @Test("prepareAssets does not overwrite an already-resolved unavailable state (one-time semantics)")
    func prepareAssetsIsOneTime() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let service = SilenceDetectionService()
        service.markCommandsUnavailable(reason: "already resolved")
        await service.prepareAssets()
        #expect(service.commandAvailability == .unavailable(reason: "already resolved"))
    }

    @Test("mock defaults to .ready so command-listener tests exercise the armed path")
    func mockDefaultsToReady() {
        let mock = MockSilenceDetectionService()
        #expect(mock.commandAvailability == .ready)
    }
}

// MARK: - SpeechAuthorizationTests (#105 — the app never requested permission)

/// WHY: grep-confirmed the app declared `NSSpeechRecognitionUsageDescription`
/// but never called `SFSpeechRecognizer.requestAuthorization` anywhere, so a
/// never-asked/denied permission silently stranded the command listener. These
/// tests pin the status→decision mapping (pure, no system dialog) and the
/// launch orchestrator that wires it into the existing `markCommandsUnavailable`
/// / `prepareAssets` seams via an injected `authorizationProvider` stub.
@Suite("SilenceDetectionService — speech authorization (#105)")
@MainActor
struct SpeechAuthorizationTests {
    @Test("authorized maps to .proceed")
    func authorizedProceeds() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        #expect(SilenceDetectionService.authorizationDecision(for: .authorized) == .proceed)
    }

    @Test("notDetermined maps to .proceed (requestAuthorization already resolved it before this runs)")
    func notDeterminedProceeds() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        #expect(SilenceDetectionService.authorizationDecision(for: .notDetermined) == .proceed)
    }

    @Test("denied maps to .unavailable with a reason that points at iOS Settings")
    func deniedMapsToUnavailableWithSettingsReason() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        guard case let .unavailable(reason) = SilenceDetectionService.authorizationDecision(for: .denied) else {
            Issue.record("Expected .unavailable for .denied")
            return
        }
        #expect(reason.contains("Settings"))
        #expect(reason.contains("Speech Recognition"))
    }

    @Test("restricted maps to .unavailable with a reason that points at iOS Settings")
    func restrictedMapsToUnavailableWithSettingsReason() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        guard case let .unavailable(reason) = SilenceDetectionService.authorizationDecision(for: .restricted) else {
            Issue.record("Expected .unavailable for .restricted")
            return
        }
        #expect(reason.contains("Settings"))
        #expect(reason.contains("Speech Recognition"))
    }

    @Test("launch orchestrator: denied authorization flips commandAvailability to .unavailable and never calls prepareAssets")
    func deniedAuthorizationSkipsAssetPrepare() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let service = SilenceDetectionService(authorizationProvider: { .denied })
        await service.requestAuthorizationAndPrepareAssets()

        guard case let .unavailable(reason) = service.commandAvailability else {
            Issue.record("Expected .unavailable, got \(service.commandAvailability)")
            return
        }
        // Distinguishes this from prepareAssets' own failure reasons (e.g.
        // "en-US not in SpeechTranscriber.supportedLocales") — proves the
        // orchestrator short-circuited BEFORE reaching asset prepare.
        #expect(reason.contains("permission denied"))
        #expect(reason.contains("Settings"))
    }

    @Test("launch orchestrator: authorized status proceeds into prepareAssets (resolves to a terminal, non-.unknown state)")
    func authorizedProceedsIntoAssetPrepare() async {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let service = SilenceDetectionService(authorizationProvider: { .authorized })
        await service.requestAuthorizationAndPrepareAssets()

        // On the simulator supportedLocales is empty → resolves .unavailable via
        // prepareAssets' OWN reason, never .unknown, and never the permission
        // reason (proving requestAuthorizationAndPrepareAssets actually called
        // through to prepareAssets rather than short-circuiting).
        #expect(service.commandAvailability != .unknown)
        if case let .unavailable(reason) = service.commandAvailability {
            #expect(!reason.contains("permission denied"))
        }
    }
}

// MARK: - EngineStartGenerationCheckTests (#100.4 — two-engine crash config)

/// WHY: `startListening()` assigns `self.audioEngine = engine` well before its
/// 50ms settle sleep, then (pre-fix) called `engine.start()` unconditionally
/// once the sleep returned. A `stopListening()` racing that sleep nils
/// `self.audioEngine`; the resumed `start()` then orphans a *running* engine
/// nobody tracks — the codebase's own "#64 two-engine crash config" — and a
/// superseding `startListening()` can spin a second, tracked engine alongside
/// it. `shouldStartEngine(_:tracking:)` is the generation-token guard the fix
/// adds: it must be a strict identity check, not merely "is still non-nil" —
/// these tests would catch either a missing guard (pre-fix: always starts) or
/// a too-weak one (accepts a *different* tracked engine).
///
/// Real AVAudioEngine/SpeechAnalyzer "can't run headlessly" (see
/// SharedEngineTests), so the guard is exercised as the pure identity function
/// production code calls through — no engine is ever started here.
@Suite("SilenceDetectionService — engine-start generation check (#100.4)")
@MainActor
struct EngineStartGenerationCheckTests {
    @Test("self.audioEngine still IS the engine we're about to start → proceed")
    func sameEngineShouldStart() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let engine = AVAudioEngine()
        #expect(SilenceDetectionService.shouldStartEngine(engine, tracking: engine))
    }

    @Test("a stopListening() ran during the settle sleep (self.audioEngine is nil) → must not start")
    func stoppedDuringSettleMustNotStart() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let engine = AVAudioEngine()
        // Pre-fix there was no guard at all: engine.start() ran unconditionally
        // here, orphaning `engine` as a running-but-untracked instance.
        #expect(!SilenceDetectionService.shouldStartEngine(engine, tracking: nil))
    }

    @Test("a superseding startListening() replaced self.audioEngine with a new engine → must not start the stale one")
    func supersededByNewEngineMustNotStart() {
        guard #available(iOS 26, *) else {
            withKnownIssue("SilenceDetectionService requires iOS 26+") {}
            return
        }
        let staleEngine = AVAudioEngine()
        let newEngine = AVAudioEngine()
        // A weaker "just check non-nil" guard would wrongly pass here — self.audioEngine
        // IS non-nil, just pointing at a different (newer) engine. The identity check
        // must catch this too, or the stale engine still gets started alongside the new one.
        #expect(!SilenceDetectionService.shouldStartEngine(staleEngine, tracking: newEngine))
    }
}
