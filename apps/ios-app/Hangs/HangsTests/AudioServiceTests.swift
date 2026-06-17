//
//  AudioServiceTests.swift
//  HangsTests
//
//  Tests for AudioService recording validation and synchronization fixes.
//  These tests help prevent regression of the 28-byte recording bug.
//

import AVFoundation
import Foundation
import Testing
@testable import Hangs

// MARK: - AudioError Tests

@Suite("AudioError Tests")
struct AudioErrorTests {

    @Test("recordingTooShort error has correct description")
    func recordingTooShortErrorDescription() {
        let error = AudioError.recordingTooShort
        #expect(error.errorDescription == "Recording too short or empty")
    }

    @Test("all audio errors have descriptions")
    func allErrorsHaveDescriptions() {
        let errors: [AudioError] = [
            .noActiveRecording,
            .recordingFailed,
            .recordingTooShort,
            .playbackFailed,
            .permissionDenied,
            .invalidBase64,
            .deviceNotFound
        ]

        for error in errors {
            #expect(error.errorDescription != nil, "Error \(error) should have a description")
        }
    }
}

// MARK: - MockAudioService Contract Tests

@Suite("MockAudioService Contract Tests")
@MainActor
struct MockAudioServiceContractTests {

    @Test("prepareForRecording stops playback")
    func prepareForRecordingStopsPlayback() async {
        let service = MockAudioService()
        service.isPlaying = true

        await service.prepareForRecording()

        #expect(service.isPlaying == false)
    }

    @Test("startRecording sets isRecording flag")
    func startRecordingSetsFlag() throws {
        let service = MockAudioService()
        #expect(service.isRecording == false)

        try service.startRecording()

        #expect(service.isRecording == true)
    }

    @Test("stopRecording returns mock data and clears flag")
    func stopRecordingReturnsMockData() async throws {
        let service = MockAudioService()
        try service.startRecording()

        let data = try await service.stopRecording()

        #expect(data == service.mockRecordingData)
        #expect(service.isRecording == false)
    }

    @Test("startRecording throws when shouldFailRecording is set")
    func startRecordingThrowsOnFailure() {
        let service = MockAudioService()
        service.shouldFailRecording = true

        #expect(throws: AudioError.recordingFailed) {
            try service.startRecording()
        }
    }

    @Test("stopRecording throws when shouldFailRecording is set")
    func stopRecordingThrowsOnFailure() async {
        let service = MockAudioService()
        service.shouldFailRecording = true

        await #expect(throws: AudioError.recordingFailed) {
            try await service.stopRecording()
        }
    }

    @Test("playOpusAudio sets and clears isPlaying")
    func playOpusAudioManagesPlayingState() async throws {
        let service = MockAudioService()
        #expect(service.isPlaying == false)

        let duration = try await service.playOpusAudio(Data())

        #expect(duration == 3.0)
        #expect(service.isPlaying == false)
    }

    // RS-11 / #59.1 — TTS spy. The real audio stack is a no-op in tests, so
    // "was TTS actually attempted" is only observable via the spy counters.
    @Test("playOpusAudio increments the spy count and records the payload")
    func playOpusAudioSpyRecordsCallAndData() async throws {
        let service = MockAudioService()
        #expect(service.playOpusCallCount == 0)
        #expect(service.lastPlayedData == nil)

        let payload = Data("tts".utf8)
        _ = try await service.playOpusAudio(payload)

        #expect(service.playOpusCallCount == 1)
        #expect(service.lastPlayedData == payload)
    }

    @Test("playOpusAudio counts the attempt even when playback fails")
    func playOpusAudioSpyCountsFailedAttempt() async {
        let service = MockAudioService()
        service.shouldFailPlayback = true

        await #expect(throws: AudioError.playbackFailed) {
            _ = try await service.playOpusAudio(Data("tts".utf8))
        }

        // The attempt happened — RS-11 relies on this to prove TTS was tried
        // even on a failure path (the quiz must not silently skip TTS).
        #expect(service.playOpusCallCount == 1)
    }

    @Test("stopPlayback clears isPlaying")
    func stopPlaybackClearsFlag() async {
        let service = MockAudioService()
        service.isPlaying = true

        await service.stopPlayback()

        #expect(service.isPlaying == false)
    }
}

// MARK: - PlaybackState Tests

@Suite("PlaybackState Tests")
struct PlaybackStateTests {

    @Test("idle state has no playback id")
    func idleStateNoPlaybackId() {
        let state = AudioService.PlaybackState.idle
        #expect(state.isIdle == true)
        #expect(state.playbackId == nil)
    }

    @Test("playing state has playback id")
    func playingStateHasId() {
        let id = UUID()
        let state = AudioService.PlaybackState.playing(id: id)
        #expect(state.isIdle == false)
        #expect(state.playbackId == id)
    }

    @Test("playback states are equatable")
    func statesAreEquatable() {
        let id1 = UUID()
        let id2 = UUID()

        #expect(AudioService.PlaybackState.idle == AudioService.PlaybackState.idle)
        #expect(AudioService.PlaybackState.playing(id: id1) == AudioService.PlaybackState.playing(id: id1))
        #expect(AudioService.PlaybackState.playing(id: id1) != AudioService.PlaybackState.playing(id: id2))
        #expect(AudioService.PlaybackState.idle != AudioService.PlaybackState.playing(id: id1))
    }
}

// MARK: - Audio Session Category Options (RS-18 / #59.3)
//
// Reads back the option set that `setupAudioSession` applies, via the pure
// `AudioService.categoryOptions(for:)` helper. This deliberately does NOT
// instantiate a live session or call `setActive`/permission — that path is the
// suspected cause of the HangsTests hang on the simulator. The guard fails the
// instant anyone strips `.allowBluetoothHFP`, which is what silently broke the
// AirPods mic in Media Mode (A2DP is output-only; the BT mic needs HFP).

@Suite("AudioSession Category Options")
struct AudioSessionCategoryOptionsTests {

    @Test("media mode includes allowBluetoothHFP so the Bluetooth mic is reachable")
    func mediaModeIncludesHFP() throws {
        let media = try #require(AudioMode.forId("media"))
        let options = AudioService.categoryOptions(for: media)

        // The bug: media mode shipped with A2DP only. A2DP is output-only, so the
        // AirPods mic was never an available input. HFP MUST stay for recording.
        #expect(options.contains(.allowBluetoothHFP))
        // A2DP must remain too — output stays high-quality and no car "call UI".
        #expect(options.contains(.allowBluetoothA2DP))
    }

    @Test("default mode is media — and it carries HFP")
    func defaultModeIsMediaWithHFP() {
        // AudioMode.default is index 1 (media). If the default ever flips back to a
        // mode without HFP, recording regresses on AirPods — pin it here.
        #expect(AudioMode.default.id == "media")
        #expect(AudioService.categoryOptions(for: .default).contains(.allowBluetoothHFP))
    }

    @Test("call mode includes both HFP and A2DP")
    func callModeIncludesHFPAndA2DP() throws {
        let call = try #require(AudioMode.forId("call"))
        let options = AudioService.categoryOptions(for: call)

        #expect(options.contains(.allowBluetoothHFP))
        #expect(options.contains(.allowBluetoothA2DP))
    }

    @Test("every mode ducks background audio")
    func everyModeDucksBackgroundAudio() {
        for mode in AudioMode.supportedModes {
            let options = AudioService.categoryOptions(for: mode)
            #expect(options.contains(.duckOthers), "\(mode.id) should duck others")
            #expect(options.contains(.defaultToSpeaker), "\(mode.id) should default to speaker")
        }
    }
}

// MARK: - Integration Test Notes
//
// The following tests require a real device or simulator with microphone access.
// They are marked as requiring explicit running since they need hardware.
//
// To run these tests:
// 1. Open Xcode
// 2. Select an iOS Simulator destination
// 3. Run tests (Cmd+U)
// 4. Grant microphone permission when prompted
//
// Manual verification steps:
// 1. Recording produces >500 bytes: Check console for "Recording data: X bytes"
// 2. Playback-to-recording transition works: Start quiz, tap record during audio
// 3. Interruptions handled: Trigger Siri during recording, verify graceful stop
// 4. Rapid double-tap microphone: Should not crash or start duplicate recordings
// 5. Start playback, immediately tap record: Clean state transition to recording
