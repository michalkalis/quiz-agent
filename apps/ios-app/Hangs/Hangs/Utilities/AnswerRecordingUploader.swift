//
//  AnswerRecordingUploader.swift
//  Hangs
//
//  #197 track 197.2 — sends the saved car answer recordings
//  (`AnswerRecordingStore`) to the backend for the replay tests, while the
//  TestFlight/debug "Save answer recordings" switch is on. Fire-and-forget:
//  the quiz only ever *kicks* it (`requestUpload`), never awaits it, so a slow
//  or failing upload can't delay an answer. A recording's local files are
//  deleted only after a 2xx; anything else stays for the next kick (the next
//  answer, or the next app start). A permanent refusal (403 consent not
//  accepted, 413 too large, 415…) drops that recording instead, so a phone
//  never piles up files the server will never take.
//

import Foundation
import os

/// The network call, so tests can stand in for the server.
nonisolated protocol VoiceSampleUploading: Sendable {
    func uploadVoiceSample(stamp: String, wav: Data, sidecarJSON: Data) async throws
}

extension NetworkService: VoiceSampleUploading {}

/// What the quiz holds: a non-blocking "there may be something to send".
nonisolated protocol AnswerRecordingUploading: Sendable {
    nonisolated func requestUpload()
}

actor AnswerRecordingUploader: AnswerRecordingUploading {
    private let transport: VoiceSampleUploading
    private let directory: URL?
    private let isEnabled: @Sendable () -> Bool
    private var isRunning = false
    private var runAgain = false

    init(
        transport: VoiceSampleUploading,
        directory: URL? = AnswerRecordingStore.directory(),
        isEnabled: @escaping @Sendable () -> Bool = { VoicePipelineFlags.saveAnswerRecordings }
    ) {
        self.transport = transport
        self.directory = directory
        self.isEnabled = isEnabled
    }

    nonisolated func requestUpload() {
        Task(priority: .utility) { await self.uploadPending() }
    }

    /// Send every complete recording, oldest first. Single-flight: a kick
    /// while a pass is running schedules one more pass instead of a second,
    /// overlapping one (which would send the same file twice).
    func uploadPending() async {
        guard isEnabled() else { return }
        if isRunning {
            runAgain = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        repeat {
            runAgain = false
            await uploadOnePass()
        } while runAgain
    }

    private func uploadOnePass() async {
        for stamp in AnswerRecordingStore.completeStamps(directory: directory) {
            guard let directory,
                  let wav = try? Data(contentsOf: directory.appendingPathComponent("\(stamp).wav")),
                  let sidecar = try? Data(contentsOf: directory.appendingPathComponent("\(stamp).json"))
            else { continue }
            do {
                try await transport.uploadVoiceSample(stamp: stamp, wav: wav, sidecarJSON: sidecar)
                AnswerRecordingStore.delete(stamp: stamp, directory: directory)
            } catch {
                if Self.isPermanentRefusal(error) {
                    AnswerRecordingStore.delete(stamp: stamp, directory: directory)
                    Logger.network.info("🎙️ Voice sample refused for good, dropped: \(error.localizedDescription, privacy: .public)")
                } else {
                    Logger.network.info("🎙️ Voice sample upload deferred: \(error.localizedDescription, privacy: .public)")
                }
                // One failure means the rest would fail the same way: stop until the next kick.
                return
            }
        }
    }

    /// A 4xx the same request will always get again. 401 (token refresh),
    /// 408 (timeout) and 429 (daily cap) can pass later, so those keep the file.
    static func isPermanentRefusal(_ error: Error) -> Bool {
        guard case let NetworkError.serverError(statusCode, _) = error else { return false }
        return (400 ..< 500).contains(statusCode) && ![401, 408, 429].contains(statusCode)
    }
}
