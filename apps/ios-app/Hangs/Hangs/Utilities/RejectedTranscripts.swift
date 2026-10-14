//
//  RejectedTranscripts.swift
//  Hangs
//
//  #204.2 (founder 2026-10-14): the player says "modrá", the app hears
//  "mokrá", the player asks to record again — and Scribe, hearing the same
//  word in the same car, returns "mokrá" again. The transcripts the player
//  threw away for the CURRENT question travel with the next upload as
//  `rejected_transcripts`, so the backend can try another hypothesis instead
//  of grading the rejected one a second time. Scoped to one question: a
//  rejection says nothing about the next question's answer.
//

import Foundation

nonisolated struct RejectedTranscripts: Equatable, Sendable {
    /// The contract's caps (issue #204): at most 5 transcripts, each at most
    /// 200 characters. The newest ones are kept.
    static let maxCount = 5
    static let maxLength = 200

    /// The question these rejections belong to (`questionId ?? ""`).
    private(set) var questionKey: String?
    private(set) var transcripts: [String] = []

    /// Remember a transcript the player rejected on `questionKey`. A different
    /// question starts a fresh list.
    mutating func add(_ transcript: String, questionKey: String) {
        if self.questionKey != questionKey {
            self = RejectedTranscripts(questionKey: questionKey)
        }
        guard let cleaned = Self.cleaned(transcript) else { return }
        transcripts.removeAll { Self.same($0, cleaned) }
        transcripts.append(cleaned)
        if transcripts.count > Self.maxCount {
            transcripts.removeFirst(transcripts.count - Self.maxCount)
        }
    }

    /// Take a rejection back — the player kept that answer after all.
    mutating func remove(_ transcript: String, questionKey: String) {
        guard self.questionKey == questionKey, let cleaned = Self.cleaned(transcript) else { return }
        transcripts.removeAll { Self.same($0, cleaned) }
    }

    /// What the next upload for `questionKey` sends; empty for any other question.
    func transcripts(for questionKey: String) -> [String] {
        self.questionKey == questionKey ? transcripts : []
    }

    /// The `rejected_transcripts` form value: a JSON array of strings, or nil
    /// when there is nothing to send (the field is then left out entirely).
    static func formValue(_ transcripts: [String]) -> String? {
        guard !transcripts.isEmpty,
              let data = try? JSONEncoder().encode(transcripts)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private init(questionKey: String) {
        self.questionKey = questionKey
    }

    init() {}

    private static func cleaned(_ transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive]) == .orderedSame
    }
}
