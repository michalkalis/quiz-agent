//
//  AudioService.swift
//  CarQuiz
//
//  Audio recording and playback service
//  @MainActor because AVFoundation requires main thread
//

import AVFoundation
import Combine
import Foundation

/// Protocol for audio operations
protocol AudioServiceProtocol: Sendable {
    var isRecording: Bool { get }
    var isPlaying: Bool { get }

    func setupAudioSession() throws
    func requestMicrophonePermission() async -> Bool
    func startRecording() throws
    func stopRecording() async throws -> Data
    func playOpusAudio(_ data: Data) async throws
    func stopPlayback()
}

/// Main actor audio service for AVFoundation operations
@MainActor
final class AudioService: NSObject, ObservableObject, AudioServiceProtocol {
    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Audio Session Setup

    func setupAudioSession() throws {
        let session = AVAudioSession.sharedInstance()

        // Configure for background playback and recording
        try session.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )

        try session.setActive(true)

        if Config.verboseLogging {
            print("🎤 Audio session configured for background playback and recording")
        }
    }

    // MARK: - Microphone Permission

    func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                if Config.verboseLogging {
                    print("🎤 Microphone permission: \(granted ? "granted" : "denied")")
                }
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Recording

    func startRecording() throws {
        // Create temporary file URL
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // Configure audio recorder settings for voice
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,  // Mono for voice
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64000  // 64kbps for voice
        ]

        audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
        audioRecorder?.delegate = self
        audioRecorder?.record()

        isRecording = true

        if Config.verboseLogging {
            print("🎤 Started recording to: \(fileName)")
        }
    }

    func stopRecording() async throws -> Data {
        guard let recorder = audioRecorder else {
            throw AudioError.noActiveRecording
        }

        recorder.stop()
        isRecording = false

        let url = recorder.url

        if Config.verboseLogging {
            print("🎤 Stopped recording")
        }

        // Read the recorded audio data
        let data = try Data(contentsOf: url)

        // Clean up temporary file
        try? FileManager.default.removeItem(at: url)

        audioRecorder = nil

        if Config.verboseLogging {
            print("🎤 Recording data: \(data.count) bytes")
        }

        return data
    }

    // MARK: - Playback

    func playOpusAudio(_ data: Data) async throws {
        // Save to temporary file for playback
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString).opus")

        try data.write(to: tempURL)

        if Config.verboseLogging {
            print("🔊 Playing audio: \(data.count) bytes")
        }

        // iOS 18+ has native Opus support via AVAudioPlayer
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()

            isPlaying = true

            // Play audio
            if audioPlayer?.play() == true {
                // Wait for playback to complete
                await withCheckedContinuation { continuation in
                    playbackContinuation = continuation
                }
            } else {
                throw AudioError.playbackFailed
            }

            // Clean up
            isPlaying = false
            try? FileManager.default.removeItem(at: tempURL)

        } catch {
            isPlaying = false
            try? FileManager.default.removeItem(at: tempURL)

            if Config.verboseLogging {
                print("❌ Playback error: \(error)")
            }

            throw AudioError.playbackFailed
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        isPlaying = false

        if let continuation = playbackContinuation {
            continuation.resume()
            playbackContinuation = nil
        }

        if Config.verboseLogging {
            print("🔊 Stopped playback")
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension AudioService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            isRecording = false
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            isRecording = false
            if Config.verboseLogging {
                print("❌ Recording error: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension AudioService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            if let continuation = playbackContinuation {
                continuation.resume()
                playbackContinuation = nil
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            isPlaying = false
            if Config.verboseLogging {
                print("❌ Playback decode error: \(error?.localizedDescription ?? "unknown")")
            }
            if let continuation = playbackContinuation {
                continuation.resume()
                playbackContinuation = nil
            }
        }
    }
}

// MARK: - Error Types

enum AudioError: LocalizedError {
    case noActiveRecording
    case recordingFailed
    case playbackFailed
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noActiveRecording:
            return "No active recording"
        case .recordingFailed:
            return "Recording failed"
        case .playbackFailed:
            return "Playback failed"
        case .permissionDenied:
            return "Microphone permission denied"
        }
    }
}

// MARK: - Mock for Testing

#if DEBUG
@MainActor
final class MockAudioService: ObservableObject, AudioServiceProtocol {
    var isRecording = false
    var isPlaying = false
    var shouldFailRecording = false
    var shouldFailPlayback = false
    var mockRecordingData = Data("mock audio".utf8)

    func setupAudioSession() throws {
        // Mock implementation
    }

    func requestMicrophonePermission() async -> Bool {
        return true
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

    func playOpusAudio(_ data: Data) async throws {
        if shouldFailPlayback {
            throw AudioError.playbackFailed
        }
        isPlaying = true
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        isPlaying = false
    }

    func stopPlayback() {
        isPlaying = false
    }
}
#endif
