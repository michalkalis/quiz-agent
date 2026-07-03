//
//  VoiceCommandMatcher.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.3 — the hands-free command
//  matcher, sibling of MCQTranscriptMatcher. A committed English transcript from
//  the on-device recognizer is mapped to a SCREEN-SCOPED VoiceCommand (or nil).
//  Because the new SpeechAnalyzer framework has no vocabulary biasing, a
//  Slovak-accented driver's "stat" must still route to `start` — so matching is
//  fuzzy (edit-distance over accent-tolerant variants) with a confidence floor
//  and word-boundary tokenization, scoped to only that screen's 1–2 commands.
//
//  `skip` is deliberately STRICT (whole-utterance, modulo filler): skipping
//  burns a freemium question, so "let's skip this one" must NOT be read as a
//  skip — the utterance must BE the skip word, not merely contain it.
//

import Foundation

/// Maps a committed English transcript to a screen-scoped hands-free command.
enum VoiceCommandMatcher {
    /// Confidence floor for a fuzzy token→command match (1 = exact). A single
    /// edit on a 5-letter word ("stat"→"start" = 0.8) clears it; noise doesn't.
    static let confidenceFloor: Double = 0.72
    /// The winning command must beat the runner-up by this margin, else the
    /// utterance is ambiguous and resolves to `nil` (never guess a wrong action).
    static let ambiguityMargin: Double = 0.15
    /// A stricter floor for the destructive `skip` word.
    static let skipFloor: Double = 0.8

    /// Resolve `transcript` to the single command valid on `screen`, or `nil`
    /// when there is no confident, unambiguous match (caller re-listens).
    ///
    /// - Parameters:
    ///   - transcript: the committed transcript from the English recognizer.
    ///   - screen: the current screen — bounds which commands are considered.
    static func match(transcript: String, on screen: VoiceCommandScreen) -> VoiceCommand? {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return nil }
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }

        let candidates = VoiceCommandLexicon.commands(on: screen)

        // Skip is strict whole-utterance — handled before (and excluded from) the
        // fuzzy token scan so it can never be triggered by a token buried in a
        // longer sentence.
        if candidates.contains(.skip), matchesStrictSkip(tokens: tokens) {
            return .skip
        }

        // Fuzzy token scan over the remaining screen commands.
        var scores: [(command: VoiceCommand, score: Double)] = []
        for command in candidates where command != .skip {
            let variants = VoiceCommandLexicon.variants(for: command)
            var best = 0.0
            for token in tokens {
                for variant in variants {
                    best = max(best, similarity(token, variant))
                }
            }
            scores.append((command, best))
        }

        scores.sort { $0.score > $1.score }
        guard let top = scores.first, top.score >= confidenceFloor else { return nil }
        if scores.count > 1, scores[1].score >= confidenceFloor,
           top.score - scores[1].score < ambiguityMargin {
            return nil // two commands too close — ambiguous
        }
        return top.command
    }

    /// STRICT skip: after stripping filler, EXACTLY one token remains and it is a
    /// confident skip variant. "skip" / "um skip please" pass; "let's skip this
    /// one" (content words remain) does not.
    private static func matchesStrictSkip(tokens: [String]) -> Bool {
        let content = tokens.filter { !VoiceCommandLexicon.fillerWords.contains($0) }
        guard content.count == 1, let token = content.first else { return false }
        let best = VoiceCommandLexicon.variants(for: .skip)
            .map { similarity(token, $0) }
            .max() ?? 0
        return best >= skipFloor
    }

    // MARK: - Scoring

    /// Normalized edit-distance similarity in [0, 1]: `1 - distance / maxLen`.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        let distance = levenshtein(Array(a), Array(b))
        return 1.0 - Double(distance) / Double(maxLen)
    }

    /// Classic iterative Levenshtein edit distance.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1, // deletion
                    current[j - 1] + 1, // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Lowercase, diacritic-fold, and reduce every non-alphanumeric run to a
    /// single space (mirrors MCQTranscriptMatcher.normalize so accent + STT
    /// punctuation don't defeat matching).
    static func normalize(_ string: String) -> String {
        let folded = string.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            scalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}

/// A pure ~2.5 s undo window opened after a destructive command (a `skip`
/// commit): a spoken cancel word ("stop"/"no"/"cancel") OR a tap that lands
/// within the window ABORTS; otherwise, once the deadline passes, the action
/// COMMITS. Pure value type — no timers, no clock ownership; the caller supplies
/// timestamps so the resolution is deterministic and testable.
struct UndoWindow: Sendable, Equatable {
    /// Default undo grace period (E-match: ~2.5 s skip-confirm undo window).
    static let defaultDuration: TimeInterval = 2.5

    /// The instant after which a cancel no longer aborts (the action commits).
    let deadline: Date

    init(startedAt: Date = Date(), duration: TimeInterval = UndoWindow.defaultDuration) {
        deadline = startedAt.addingTimeInterval(duration)
    }

    enum Resolution: Sendable, Equatable {
        case abort // cancelled in time — do NOT perform the action
        case commit // window elapsed (or cancel too late) — perform the action
    }

    /// Whether the window is still accepting a cancel at `now`.
    func isOpen(at now: Date) -> Bool { now < deadline }

    /// Resolve the window. A `cancelledAt` timestamp aborts iff it lands within
    /// the window (`<= deadline`); `nil` (no cancel) or a late cancel commits.
    func resolve(cancelledAt: Date?) -> Resolution {
        guard let cancelledAt, cancelledAt <= deadline else { return .commit }
        return .abort
    }
}
