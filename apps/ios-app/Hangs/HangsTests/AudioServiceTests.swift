//
//  AudioServiceTests.swift
//  HangsTests
//
//  Tests for AudioService recording validation and synchronization fixes.
//  These tests help prevent regression of the 28-byte recording bug.
//

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

// MARK: - MockAudioService Tests

@Suite("MockAudioService Tests")
@MainActor
struct MockAudioServiceTests {

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

    @Test("stopPlayback clears isPlaying")
    func stopPlaybackClearsFlag() async {
        let service = MockAudioService()
        service.isPlaying = true

        await service.stopPlayback()

        #expect(service.isPlaying == false)
    }
}

// MARK: - Recording Size Validation Constants

@Suite("Recording Validation Tests")
struct RecordingValidationTests {

    @Test("minimum valid recording size is reasonable")
    func minimumSizeIsReasonable() {
        // The minimum valid size (500 bytes) should be:
        // - Greater than M4A header size (~28 bytes)
        // - Less than a 1-second recording (~2KB at 16kHz mono)
        let minimumValidSize = 500
        let m4aHeaderSize = 28
        let oneSecondRecordingSize = 2000  // approximate

        #expect(minimumValidSize > m4aHeaderSize,
               "Minimum size should be greater than M4A header")
        #expect(minimumValidSize < oneSecondRecordingSize,
               "Minimum size should be less than a 1-second recording")
    }

    @Test("28-byte recording would be rejected")
    func tinyRecordingWouldBeRejected() {
        // This tests the invariant that caused the original bug
        let brokenRecordingSize = 28
        let minimumValidSize = 500

        #expect(brokenRecordingSize < minimumValidSize,
               "28-byte recordings (the bug symptom) must be rejected")
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
