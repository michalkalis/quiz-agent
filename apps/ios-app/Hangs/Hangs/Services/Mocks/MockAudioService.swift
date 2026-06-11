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

        // Device management
        var availableInputDevices: [AudioDevice] = [.previewBuiltIn, .previewBluetooth]
        var currentInputDevice: AudioDevice?
        var currentOutputDeviceName: String = "iPhone"

        func setupAudioSession(mode _: AudioMode) throws {
            // Mock implementation
        }

        func deactivateSession() {
            // Mock implementation
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
            if shouldFailRecording {
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

        func playOpusAudio(_: Data) async throws -> TimeInterval {
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
            isPlaying = false
        }

        func startStreamingRecording(onChunk _: @escaping PCMChunkHandler) throws {
            if shouldFailRecording {
                throw AudioError.recordingFailed
            }
            isRecording = true
        }

        func stopStreamingRecording() {
            isRecording = false
        }

        func refreshAvailableDevices() {
            // Mock: devices don't change
        }

        func setPreferredInputDevice(_ device: AudioDevice?) throws {
            currentInputDevice = device
        }
    }
#endif
