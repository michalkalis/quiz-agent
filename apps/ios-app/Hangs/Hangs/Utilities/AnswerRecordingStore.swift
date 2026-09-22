//
//  AnswerRecordingStore.swift
//  Hangs
//
//  #184 track B — the car-sample collector. When the founder opts in
//  (`VoicePipelineFlags.saveAnswerRecordings`, TestFlight/debug Settings), every
//  batch answer recording is kept as `<stamp>.wav` plus a `<stamp>.json`
//  sidecar (language, input route, voice-processing state, duration, and the
//  backend transcript once it lands) under Documents/AnswerRecordings. The
//  offline comparison script feeds those WAVs to Scribe batch / Azure / today's
//  realtime path against a hand transcript. Recordings never leave the device
//  unless the founder exports them from Settings (share sheet). Nothing here
//  runs on the quiz hot path unless the switch is on.
//

import Foundation
import os

nonisolated enum AnswerRecordingStore {
    struct Sidecar: Codable, Sendable, Equatable {
        var recordedAt: Date
        var language: String
        var inputPort: String
        var voiceProcessing: Bool
        var sampleRate: Int
        var durationMs: Int
        var questionId: String?
        var transcript: String?
        var provider: String?
    }

    static let folderName = "AnswerRecordings"

    static func directory(base: URL? = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first) -> URL? {
        base?.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Save one recording. Returns the stamp (basename) so the transcript can be
    /// attached later, or `nil` when saving is off or failed (logged).
    @discardableResult
    static func save(wav: Data, sidecar: Sidecar, enabled: Bool = VoicePipelineFlags.saveAnswerRecordings, directory: URL? = directory()) -> String? {
        guard enabled, let directory else { return nil }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = Self.stamp(for: sidecar.recordedAt)
            try wav.write(to: directory.appendingPathComponent("\(stamp).wav"))
            try writeSidecar(sidecar, stamp: stamp, directory: directory)
            return stamp
        } catch {
            Logger.audio.warning("💾 Answer recording save failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Attach the transcript (and which STT provider produced it) to a saved
    /// recording's sidecar. No-op when the stamp is unknown.
    static func attachTranscript(_ transcript: String, provider: String?, to stamp: String, directory: URL? = directory()) {
        guard let directory else { return }
        let url = directory.appendingPathComponent("\(stamp).json")
        guard let data = try? Data(contentsOf: url),
              var sidecar = try? decoder.decode(Sidecar.self, from: data) else { return }
        sidecar.transcript = transcript
        sidecar.provider = provider
        try? writeSidecar(sidecar, stamp: stamp, directory: directory)
    }

    /// Every saved file (WAV + JSON), sorted — the share-sheet payload.
    static func files(directory: URL? = directory()) -> [URL] {
        guard let directory,
              let items = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return items.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Number of recordings kept (WAV count).
    static func recordingCount(directory: URL? = directory()) -> Int {
        files(directory: directory).filter { $0.pathExtension == "wav" }.count
    }

    static func deleteAll(directory: URL? = directory()) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    static func stamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func writeSidecar(_ sidecar: Sidecar, stamp: String, directory: URL) throws {
        let data = try encoder.encode(sidecar)
        try data.write(to: directory.appendingPathComponent("\(stamp).json"))
    }
}
