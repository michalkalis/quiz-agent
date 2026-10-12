//
//  AnswerRecordingStore.swift
//  Hangs
//
//  #184 track B — the car-sample collector. When the founder opts in
//  (`VoicePipelineFlags.saveAnswerRecordings`, TestFlight/debug Settings), every
//  batch answer recording is kept as `<stamp>.wav` plus a `<stamp>.json`
//  sidecar (language, input and output route, voice-processing state and
//  policy mode, what was uploaded, duration, and the backend transcript once
//  it lands) under Documents/AnswerRecordings. The offline comparison script
//  feeds those WAVs to Scribe batch / Azure / today's realtime path against a
//  hand transcript. #197: once the answer is decided the sidecar also carries
//  the session/question context and the app's decision, and
//  `AnswerRecordingUploader` sends the pair to our backend for the replay
//  tests (deleting the local copy only after a 2xx). Nothing here runs on the
//  quiz hot path unless the switch is on.
//

import Foundation
import os

nonisolated enum AnswerRecordingStore {
    struct Sidecar: Codable, Sendable, Equatable {
        var recordedAt: Date
        var language: String
        var inputPort: String
        /// Whether the recording engine's input node had voice processing on.
        var voiceProcessing: Bool
        /// #185 track C: where the quiz's sound went during the answer and
        /// the policy mode behind `voiceProcessing` (`VoiceProcessingMode`).
        /// Optional so sidecars written before them still decode.
        var outputPort: String?
        var voiceProcessingMode: String?
        /// #185 track C: what the backend transcribed — `raw` or `hpf_norm`
        /// (`AnswerAudioConditioning`). The saved WAV is always the raw one.
        var uploadConditioning: String?
        var sampleRate: Int
        var durationMs: Int
        var questionId: String?
        var transcript: String?
        var provider: String?
        /// #197 (track 197.1): the context the replay needs to grade the
        /// recording again — the question as the app showed it (translated
        /// text and options) and, once graded, the served correct answer.
        var sessionId: String?
        var questionType: String?
        var questionText: String?
        var options: [String: String]?
        var correctAnswer: String?
        var headlineAnswer: String?
        /// What the app decided for this recording — see `Outcome.decision`.
        var appDecision: String?
        /// #197.6: audio time (ms) the energy VAD heard speech start / the
        /// last speech end — lets the replay tell a late start from a late stop.
        var firstSpeechMs: Int?
        var lastSpeechEndMs: Int?
    }

    /// #197: what the app decided for one recording. `decision` is the
    /// backend verdict (`correct`, `incorrect`, `partially_correct`,
    /// `partially_incorrect`, `skipped`), `not_captured:<code>` when the
    /// server asked to say it again (`no_speech`, `no_answer`,
    /// `mcq_unmatched`; `empty` when the transcript came back empty; bare
    /// `not_captured` for an uncoded 400), `cancelled` or `error`.
    /// `scripts/voice_replay.py` speaks the same vocabulary.
    struct Outcome: Sendable, Equatable {
        var decision: String
        var transcript: String?
        var correctAnswer: String?
        var headlineAnswer: String?

        static let error = Outcome(decision: "error")

        static func notCaptured(_ code: String?) -> Outcome {
            Outcome(decision: code.map { "not_captured:\($0)" } ?? "not_captured")
        }
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

    /// #197: record what the app decided (and heard) for a saved recording.
    /// No-op when the stamp is unknown.
    static func recordOutcome(_ outcome: Outcome, to stamp: String, directory: URL? = directory()) {
        updateSidecar(stamp: stamp, directory: directory) { sidecar in
            sidecar.appDecision = outcome.decision
            if let transcript = outcome.transcript { sidecar.transcript = transcript }
            if let correct = outcome.correctAnswer { sidecar.correctAnswer = correct }
            if let headline = outcome.headlineAnswer { sidecar.headlineAnswer = headline }
        }
    }

    /// #197: stamps with both the WAV and the sidecar on disk, oldest first —
    /// what the uploader sends.
    static func completeStamps(directory: URL? = directory()) -> [String] {
        let names = Set(files(directory: directory).map(\.lastPathComponent))
        return names
            .filter { $0.hasSuffix(".wav") }
            .map { String($0.dropLast(4)) }
            .filter { names.contains("\($0).json") }
            .sorted()
    }

    /// #197: drop one recording (after the server has it).
    static func delete(stamp: String, directory: URL? = directory()) {
        guard let directory else { return }
        for ext in ["wav", "json"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stamp).\(ext)"))
        }
    }

    private static func updateSidecar(stamp: String, directory: URL?, _ change: (inout Sidecar) -> Void) {
        guard let directory else { return }
        let url = directory.appendingPathComponent("\(stamp).json")
        guard let data = try? Data(contentsOf: url),
              var sidecar = try? decoder.decode(Sidecar.self, from: data) else { return }
        change(&sidecar)
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
