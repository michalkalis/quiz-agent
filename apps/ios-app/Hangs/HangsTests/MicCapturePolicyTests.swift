//
//  MicCapturePolicyTests.swift
//  HangsTests
//
//  #204.4 / #204.5 — cleaner car mic without voice processing. Why these
//  tests matter: the car test of 2026-09-23 showed what happens when the
//  session is touched on the wrong route (the car stereo went quiet). So:
//  - echo-cancelled input (and the `.default` mode it needs) only on the
//    routes voice processing is off on — the speaker / HFP path keeps exactly
//    today's `.spokenAudio` session;
//  - the front cardioid mic only on the built-in mic without voice
//    processing, and the built-in mic is never pinned over HFP / Call Mode or
//    an input the player picked.
//

@preconcurrency import AVFoundation
import Foundation
@testable import Hangs
import Testing

@Suite("Mic capture policy — echo-cancelled input + front cardioid (#204.4/#204.5)")
struct MicCapturePolicyTests {
    @Test("echo-cancelled input on car and headphone routes when the switch is on")
    func echoCancelledInputOnExternalRoutes() {
        for output in [AVAudioSession.Port.bluetoothA2DP, .bluetoothLE, .carAudio, .headphones] {
            #expect(MicCapturePolicy.wantsEchoCancelledInput(outputs: [output], enabled: true), "\(output.rawValue)")
            #expect(!MicCapturePolicy.wantsEchoCancelledInput(outputs: [output], enabled: false), "off = today's session")
        }
    }

    @Test("the speaker / receiver / HFP path is never touched")
    func speakerAndHFPUntouched() {
        // Voice processing already cancels the echo there; changing the mode
        // would change a path that works.
        for output in [AVAudioSession.Port.builtInSpeaker, .builtInReceiver, .bluetoothHFP] {
            #expect(!MicCapturePolicy.wantsEchoCancelledInput(outputs: [output], enabled: true), "\(output.rawValue)")
        }
    }

    @Test("an unknown, empty or mixed route keeps today's session")
    func unknownRoutesUntouched() {
        #expect(!MicCapturePolicy.wantsEchoCancelledInput(outputs: [], enabled: true))
        #expect(!MicCapturePolicy.wantsEchoCancelledInput(outputs: [.airPlay], enabled: true))
        #expect(!MicCapturePolicy.wantsEchoCancelledInput(outputs: [.bluetoothA2DP, .builtInSpeaker], enabled: true))
    }

    @Test("echo-cancelled input swaps only the mode, to the one Apple supports it in")
    func echoCancelledConfigurationChangesOnlyMode() throws {
        for id in ["media", "call"] {
            let mode = try #require(AudioMode.forId(id))
            let base = AudioService.quizSessionConfiguration(for: mode)
            let echoCancelled = AudioService.quizSessionConfiguration(for: mode, echoCancelledInput: true)
            // SDK header: valid only with .playAndRecord + .default.
            #expect(echoCancelled.mode == .default)
            #expect(echoCancelled.category == .playAndRecord)
            // Same Bluetooth options = the sound stays on the car route.
            #expect(echoCancelled.options == base.options, "\(id) must keep its route options")
        }
    }

    @Test("front cardioid only on the built-in mic without voice processing")
    func frontCardioidOnlyOnRawBuiltInMic() {
        #expect(MicCapturePolicy.wantsFrontCardioidMic(inputs: [.builtInMic], enabled: true, voiceProcessing: false))
        #expect(!MicCapturePolicy.wantsFrontCardioidMic(inputs: [.builtInMic], enabled: false, voiceProcessing: false))
        #expect(
            !MicCapturePolicy.wantsFrontCardioidMic(inputs: [.builtInMic], enabled: true, voiceProcessing: true),
            "the voice-processing unit picks its own mics"
        )
        for input in [AVAudioSession.Port.bluetoothHFP, .headsetMic, .carAudio, .usbAudio] {
            #expect(
                !MicCapturePolicy.wantsFrontCardioidMic(inputs: [input], enabled: true, voiceProcessing: false),
                "an external mic in use is never overridden: \(input.rawValue)"
            )
        }
    }

    @Test("the built-in mic is pinned only in Media Mode and never over someone else's choice")
    func pinOnlyInMediaMode() {
        #expect(MicCapturePolicy.shouldPinBuiltInMic(audioModeId: "media", hasForeignPreferredInput: false))
        #expect(
            !MicCapturePolicy.shouldPinBuiltInMic(audioModeId: "call", hasForeignPreferredInput: false),
            "a pin in Call Mode would keep the car's hands-free mic from taking over"
        )
        #expect(
            !MicCapturePolicy.shouldPinBuiltInMic(audioModeId: "media", hasForeignPreferredInput: true),
            "the input the player picked wins"
        )
    }
}
