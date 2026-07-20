//
//  MockAudioService.swift
//  Hangs
//
//  Mock AudioService for DEBUG builds (SwiftUI previews, UI-test mode).
//

@preconcurrency import AVFoundation
import Combine
import Foundation
import os

#if DEBUG
    @MainActor
    final class MockAudioService: ObservableObject, AudioServiceProtocol {
        var isRecording = false
        var isPlaying = false
        var shouldFailRecording = false
        var shouldFailPlayback = false
        var mockRecordingData = Data("mock audio".utf8)

        // #67 Part A. Mirrors the real service's streaming-engine liveness so the
        // interruption teardown can be exercised headlessly. `startStreamingRecording`
        // marks it live; `stopStreamingRecording` clears it (like `audioEngine = nil`).
        private(set) var audioEngineActive = false
        var onInterruptionBegan: (@MainActor @Sendable () -> Void)?

        /// Drive a `.began` interruption through the SAME routing decision the real
        /// AudioService uses, so this mock can never drift from production behaviour.
        func simulateInterruptionBegan() {
            // A real interruption has the system deactivate the audio session
            // underneath the app — mirror that so `.ended` has something to recover.
            sessionActive = false
            switch AudioService.interruptionTeardown(
                isStreaming: audioEngineActive,
                isRecording: isRecording
            ) {
            case .streaming:
                stopStreamingRecording()
                onInterruptionBegan?()
            case .batch:
                isRecording = false
            case .none:
                break
            }
        }

        // #100.3. Mirrors whether the real AVAudioSession is active, so the
        // "mic doesn't recover after a call" regression is observable headlessly:
        // `startRecording`/`startStreamingRecording` fail while the session is
        // inactive, exactly like the real `engine.start()`/`record()` do.
        private(set) var sessionActive = true

        /// Drive a `.ended` interruption through the SAME decision the real
        /// AudioService uses, so this mock can never drift from production behaviour.
        func simulateInterruptionEnded(options: AVAudioSession.InterruptionOptions) {
            if AudioService.shouldResumeSession(options: options) {
                sessionActive = true
            }
        }

        // TTS spy (RS-11 / #59.1): the real audio stack is replaced by a no-op in
        // tests, so "was TTS actually attempted" is otherwise unobservable. Every
        // playOpusAudio call increments the count and records the last payload, even
        // when shouldFailPlayback throws (the attempt still happened).
        var playOpusCallCount = 0
        var lastPlayedData: Data?

        /// Stop spy (tap-to-replay restart contract): proves an in-flight TTS was
        /// actually stopped before the restarted playback, which is otherwise
        /// unobservable with the no-op audio stack.
        var stopPlaybackCallCount = 0

        // Device management
        var availableInputDevices: [AudioDevice] = [.previewBuiltIn, .previewBluetooth]
        var currentInputDevice: AudioDevice?
        var currentOutputDeviceName: String = "iPhone"

        func setupAudioSession(mode _: AudioMode) throws {
            // Mock implementation
        }

        /// Counts deactivations so the scene-phase teardown tests can assert the
        /// session is released only when idle (never under in-flight TTS).
        var deactivateSessionCallCount = 0

        func deactivateSession() {
            deactivateSessionCallCount += 1
        }

        func switchAudioMode(_: AudioMode) async throws {
            // Mock implementation
        }

        var micPermissionResult = true

        func requestMicrophonePermission() async -> Bool {
            return micPermissionResult
        }

        func prepareForRecording() async {
            isPlaying = false
        }

        func startRecording() throws {
            if shouldFailRecording || !sessionActive {
                throw AudioError.recordingFailed
            }
            isRecording = true
        }

        func stopRecording() async throws -> Data {
            isRecording = false
            if shouldFailRecording {
                throw AudioError.recordingFailed
            }
            return mockRecordingData
        }

        func playOpusAudio(_ data: Data) async throws -> TimeInterval {
            playOpusCallCount += 1
            lastPlayedData = data
            if shouldFailPlayback {
                throw AudioError.playbackFailed
            }
            isPlaying = true
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            isPlaying = false
            return 3.0 // Mock duration
        }

        func playOpusAudioFromBase64(_ base64: String) async throws -> TimeInterval {
            guard Data(base64Encoded: base64) != nil else {
                throw AudioError.invalidBase64
            }
            return try await playOpusAudio(Data())
        }

        func stopPlayback() async {
            stopPlaybackCallCount += 1
            isPlaying = false
        }

        /// The real service invokes this on an audio thread with each PCM chunk.
        /// The mock never runs a live engine, so it stores the handler and lets a
        /// test pump chunks through `emitStreamingChunk` — needed to exercise the
        /// #109 feedback WAV-tee headlessly.
        private(set) var streamingChunkHandler: PCMChunkHandler?

        func startStreamingRecording(onChunk: @escaping PCMChunkHandler) async throws {
            if shouldFailRecording || !sessionActive {
                throw AudioError.recordingFailed
            }
            isRecording = true
            audioEngineActive = true
            streamingChunkHandler = onChunk
        }

        func stopStreamingRecording() {
            isRecording = false
            audioEngineActive = false
            streamingChunkHandler = nil
        }

        /// Test seam (#109): drive a PCM chunk through the streaming handler, as the
        /// real AVAudioEngine tap would, so the feedback WAV-tee can be verified.
        func emitStreamingChunk(_ data: Data) {
            streamingChunkHandler?(data)
        }

        func refreshAvailableDevices() {
            // Mock: devices don't change
        }

        func setPreferredInputDevice(_ device: AudioDevice?) throws {
            currentInputDevice = device
        }
    }
#endif
