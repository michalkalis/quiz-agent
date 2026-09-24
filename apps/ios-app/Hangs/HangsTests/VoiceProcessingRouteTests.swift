//
//  VoiceProcessingRouteTests.swift
//  HangsTests
//
//  #185 track C — sound stays in the car's Bluetooth. Car test 2026-09-23:
//  with voice processing armed (#184), iOS switched the session to `.voiceChat`
//  implicitly, the car's A2DP stereo dropped out of the route and every sound
//  of the quiz played from the iPhone speaker. Why these tests matter:
//  - The route → mode table IS the founder decision (A + B): voice processing
//    only where it cannot move the sound (iPhone speaker, Call Mode's HFP),
//    never on A2DP / CarPlay / AirPlay / wired, and the diagnostics switch that
//    reproduces the old behaviour must say so in the logs.
//  - A listener whose voice processing hides the car must be re-armed when a
//    device arrives, but never in a loop (arming and restoring cause route
//    changes themselves).
//  - A session left on `.voiceChat` must be put back, and only then.
//  The quiz-flow half (restart, restore ordering, Settings) lives in
//  VoiceProcessingRouteFlowTests.swift.
//

@preconcurrency import AVFoundation
import Foundation
@testable import Hangs
import Testing

// MARK: - Route → mode

@Suite("Voice processing policy — route decides (#185 C)")
struct VoiceProcessingPolicyTests {
    private func mode(
        _ outputs: [AVAudioSession.Port],
        enabled: Bool = true,
        force: Bool = false
    ) -> VoiceProcessingMode {
        VoiceProcessingPolicy.mode(outputs: outputs, enabled: enabled, forceOnExternalOutput: force)
    }

    @Test("the car's A2DP output never gets voice processing by default")
    func carA2DPStaysOff() {
        // The 09-23 finding: arming it here pulls the sound onto the iPhone.
        #expect(mode([.bluetoothA2DP]) == .offOutput)
    }

    @Test(
        "every external media output keeps voice processing off",
        arguments: [
            AVAudioSession.Port.bluetoothA2DP, .bluetoothLE, .carAudio, .airPlay,
            .headphones, .usbAudio, .HDMI, .lineOut,
        ]
    )
    func externalOutputsStayOff(port: AVAudioSession.Port) {
        #expect(mode([port]) == .offOutput)
        #expect(!mode([port]).armsVoiceProcessing)
    }

    @Test(
        "the iPhone's own output and Call Mode's hands-free route get it",
        arguments: [AVAudioSession.Port.builtInSpeaker, .builtInReceiver, .bluetoothHFP]
    )
    func phoneAndHandsFreeGetIt(port: AVAudioSession.Port) {
        // Nothing to lose there: the sound already is where voiceChat would put it.
        #expect(mode([port]) == .on)
        #expect(mode([port]).armsVoiceProcessing)
    }

    @Test("an unknown or mixed route stays off")
    func unknownOrMixedRouteStaysOff() {
        // Worst case the answer is unprocessed — never that the car goes quiet.
        #expect(mode([]) == .offOutput)
        #expect(mode([.builtInSpeaker, .airPlay]) == .offOutput)
    }

    @Test("the master switch wins over the route and over the force switch")
    func masterSwitchWins() {
        #expect(mode([.builtInSpeaker], enabled: false) == .offSwitch)
        #expect(mode([.bluetoothA2DP], enabled: false, force: true) == .offSwitch)
    }

    @Test("the force switch reproduces the #184 behaviour and says so")
    func forceSwitchIsVisible() {
        // The logs must tell a forced recording from a normal one, so the
        // in-car comparison can separate the two cells.
        #expect(mode([.bluetoothA2DP], force: true) == .forcedOn)
        #expect(mode([.bluetoothA2DP], force: true).armsVoiceProcessing)
        // On the phone speaker nothing was forced.
        #expect(mode([.builtInSpeaker], force: true) == .on)
    }
}

// MARK: - When a live listener is restarted

@Suite("Voice processing policy — route change restarts (#185 C)")
struct VoiceProcessingRestartDecisionTests {
    private func restart(_ reason: AVAudioSession.RouteChangeReason, armed: Bool, wants: Bool) -> Bool {
        VoiceProcessingPolicy.shouldRestartListener(reason: reason, armed: armed, wantsVoiceProcessing: wants)
    }

    @Test("a new device while voice processing runs restarts, even if the route still reads as the speaker")
    func newDeviceUnderVoiceProcessing() {
        // While the unit runs iOS hides A2DP, so the car connecting shows up
        // as "still the speaker"; only releasing the unit reveals it.
        #expect(restart(.newDeviceAvailable, armed: true, wants: true))
        #expect(restart(.newDeviceAvailable, armed: true, wants: false))
    }

    @Test("the car connecting to a listener that already runs without voice processing changes nothing")
    func newDeviceWithoutVoiceProcessing() {
        #expect(!restart(.newDeviceAvailable, armed: false, wants: false))
        // …but a hands-free headset in Call Mode does want it.
        #expect(restart(.newDeviceAvailable, armed: false, wants: true))
    }

    @Test("a device leaving restarts only when the verdict flips")
    func oldDeviceFlip() {
        #expect(restart(.oldDeviceUnavailable, armed: false, wants: true), "car gone → phone speaker gets voice processing back")
        #expect(restart(.oldDeviceUnavailable, armed: true, wants: false))
        #expect(!restart(.oldDeviceUnavailable, armed: true, wants: true))
        #expect(!restart(.oldDeviceUnavailable, armed: false, wants: false))
    }

    @Test(
        "route changes our own arming and restore cause never restart",
        arguments: [
            AVAudioSession.RouteChangeReason.categoryChange, .override, .routeConfigurationChange,
            .wakeFromSleep, .noSuitableRouteForCategory, .unknown,
        ]
    )
    func selfInflictedChangesNeverRestart(reason: AVAudioSession.RouteChangeReason) {
        // Arming the unit and restoring the session both post these; reacting
        // to them would restart the listener in a loop.
        #expect(!restart(reason, armed: true, wants: false))
        #expect(!restart(reason, armed: false, wants: true))
    }
}

// MARK: - Session restore + decoding

@Suite("Audio session restore and route decoding (#185 C)")
@MainActor
struct AudioSessionRestoreTests {
    private let quiz = AudioService.quizSessionConfiguration(for: AudioMode.forId("media") ?? .default)

    @Test("the implicit .voiceChat a voice-processing engine leaves behind is restored")
    func voiceChatDriftRestores() {
        #expect(AudioService.sessionNeedsRestore(configured: quiz, category: .playAndRecord, mode: .voiceChat))
    }

    @Test("a session on its own configuration is left alone")
    func noDriftNoRestore() {
        // The car path: voice processing never ran, so nothing may be re-set.
        #expect(!AudioService.sessionNeedsRestore(configured: quiz, category: quiz.category, mode: quiz.mode))
    }

    @Test("with no configuration applied yet nothing is invented")
    func noConfigurationNoRestore() {
        #expect(!AudioService.sessionNeedsRestore(configured: nil, category: .playAndRecord, mode: .voiceChat))
    }

    @Test("the log names the reason and the mode without the SDK prefix")
    func readableNames() {
        #expect(AudioService.routeChangeReasonName(.newDeviceAvailable) == "newDeviceAvailable")
        #expect(AudioService.routeChangeReasonName(.oldDeviceUnavailable) == "oldDeviceUnavailable")
        #expect(VoiceProcessingPolicy.modeName(.voiceChat) == "VoiceChat")
        #expect(VoiceProcessingPolicy.modeName(.spokenAudio) == "SpokenAudio")
    }

    @Test("a posted route change reaches the owner with its reason")
    func postedRouteChangeReachesOwner() async {
        // The owner can only re-arm the listener if every system route change
        // actually reaches it, decoded from the NSNumber payload iOS sends.
        let center = NotificationCenter()
        let service = AudioService(notificationCenter: center)
        service.registerSessionObservers()
        var received: AudioRouteChange?
        service.onRouteChange = { received = $0 }

        center.post(Notification(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)]
        ))
        await pumpUntil({ received != nil }, "the route change must reach the owner")

        #expect(received?.reason == .newDeviceAvailable)
        #expect(received?.previousOutputPort == "none", "no previous route in the payload → none, never a guess")
    }
}
