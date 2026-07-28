//
//  VoiceCommandMatcher.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.3 — the hands-free command
//  matcher, sibling of MCQTranscriptMatcher. A transcript from the on-device
//  recognizer — a VOLATILE hypothesis or a final, since #119 (see `isFinal`) —
//  is mapped to a SCREEN-SCOPED VoiceCommand (or nil). Matching is fuzzy (a
//  one-edit distance tolerance over each command's canonical spelling) with a
//  confidence floor and word-boundary tokenization, scoped to only that screen's
//  1–2 commands. #119 deleted the hand-written accent-variant tables: 24 real
//  field transcripts contained not one accent-mangled form, because an en-US
//  language model snaps its output to dictionary words rather than phonetic
//  spellings — the tolerance is what covers the accent, not a variant list.
//
//  `skip` is deliberately STRICT (whole-utterance, modulo filler): skipping
//  burns a freemium question, so "let's skip this one" must NOT be read as a
//  skip — the utterance must BE the skip word, not merely contain it.
//
//  #119 (build-33 field data): ALL commands are additionally capped at
//  `maxContentTokens` content tokens — see the gate in `match` — and a VOLATILE
//  hypothesis is held to a stricter confidence floor than a final.
//

import Foundation

/// Maps an English transcript — volatile hypothesis or final — to a
/// screen-scoped hands-free command.
enum VoiceCommandMatcher {
    /// Confidence floor for a fuzzy token→command match (1 = exact). A single
    /// edit on a 5-letter word ("stat"→"start" = 0.8) clears it; noise doesn't.
    static let confidenceFloor: Double = 0.72
    /// A stricter floor for a VOLATILE hypothesis (#119). A volatile is revisable
    /// by design and arrives while the mic is still open to the road, the radio
    /// and the passenger, so only a near-exact word may act on one. There is no
    /// recall cost: the build-33 unmatched field transcripts sit at ~0.50, far
    /// below either floor, while a real command word transcribes perfectly (1.0).
    /// What this drops is one-edit noise on a short word ("star"/"gain" → 0.80).
    static let volatileConfidenceFloor: Double = 0.85
    /// The winning command must beat the runner-up by this margin, else the
    /// utterance is ambiguous and resolves to `nil` (never guess a wrong action).
    static let ambiguityMargin: Double = 0.15
    /// A stricter floor for the destructive `skip` word.
    static let skipFloor: Double = 0.8
    /// Upper bound on DISTINCT content tokens (filler stripped, duplicates
    /// collapsed) for an utterance to be treated as a command at all. ONE,
    /// because every word in this grammar is one word — see the gate in `match`.
    static let maxContentTokens = 1

    /// Resolve `transcript` to the single command valid on `screen`, or `nil`
    /// when there is no confident, unambiguous match (caller re-listens).
    ///
    /// - Parameters:
    ///   - transcript: a transcript from the command recognizer — since #119 a
    ///     volatile hypothesis as well as a final (see `isFinal`).
    ///   - screen: the current screen — bounds which commands are considered.
    ///   - isFinal: whether this is a finalized transcript. A volatile hypothesis
    ///     is scored against the stricter `volatileConfidenceFloor`.
    ///   - language: the command grammar language (#120). Defaults to the
    ///     launch-time selection so call sites above the engine seam are
    ///     unchanged; tests pin it explicitly.
    static func match(
        transcript: String, on screen: VoiceCommandScreen, isFinal: Bool = true,
        language: CommandLanguage = CommandEngineSelection.current.commandLanguage
    ) -> VoiceCommand? {
        let normalized = normalize(transcript)
        guard !normalized.isEmpty else { return nil }
        let tokens = normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }

        // #119 content-token cap — the first gate, for every command on every
        // screen. Every word in this grammar is ONE word, and the build-33 field
        // data shows real commands arriving as a bare word, often repeated
        // ("start start start start start") when nothing responds — while every
        // false-positive candidate was conversational speech or TTS bleed of 3+
        // tokens ("what about guys come in", "he is proud of you"). Those are not
        // near-misses (best score ~0.50 against the floor), so no threshold
        // separates them; length does.
        //
        // The cap sees ONE delivered transcript, so it does NOT protect the
        // leading edge of a volatile hypothesis: the transcriber emits a GROWING
        // hypothesis, so every sentence passes through a 1-token prefix state
        // ("Okay, tak to bolo dobré" → volatile "okay"). That hole is closed in
        // VoiceCommandCoordinator+Utterance, which requires a volatile to be
        // proven to have STOPPED GROWING before it may fire. Either of two
        // independent signals proves that: an unchanged re-delivery, or
        // `volatileSettleDelay` elapsing with no newer hypothesis
        // (`armVolatileSettle`). Only the second is contractual — Apple emits a
        // volatile when the hypothesis CHANGES, never on a timer — so the settle
        // is the real gate and the re-delivery is an accelerator.
        guard contentTokens(tokens, language: language).count <= maxContentTokens else { return nil }

        let candidates = VoiceCommandLexicon.commands(on: screen)

        // Skip is strict whole-utterance — handled before (and excluded from) the
        // fuzzy token scan so it can never be triggered by a token buried in a
        // longer sentence.
        if candidates.contains(.skip), matchesStrictSkip(tokens: tokens, language: language) {
            return .skip
        }

        // Fuzzy token scan over the remaining screen commands.
        var scores: [(command: VoiceCommand, score: Double)] = []
        for command in candidates where command != .skip {
            let variants = VoiceCommandLexicon.variants(for: command, language: language)
            var best = 0.0
            for token in tokens {
                for variant in variants {
                    best = max(best, similarity(token, variant))
                }
            }
            scores.append((command, best))
        }

        let floor = isFinal ? confidenceFloor : volatileConfidenceFloor
        scores.sort { $0.score > $1.score }
        guard let top = scores.first, top.score >= floor else { return nil }
        if scores.count > 1, scores[1].score >= floor,
           top.score - scores[1].score < ambiguityMargin
        {
            return nil // two commands too close — ambiguous
        }
        return top.command
    }

    /// #122 Track A: whether a normalized utterance still carries at least one
    /// non-filler token — the content-bearing gate for the unmatched-feedback
    /// throttle. Lives here so the feedback path and the matcher share one
    /// filler definition.
    static func hasContentTokens(
        _ normalized: String,
        language: CommandLanguage = CommandEngineSelection.current.commandLanguage
    ) -> Bool {
        let tokens = normalized.split(separator: " ").map(String.init)
        return !contentTokens(tokens, language: language).isEmpty
    }

    /// The DISTINCT content tokens of an utterance: filler stripped, duplicates
    /// collapsed. Duplicates collapse because a driver repeating an unanswered
    /// command is still saying ONE word (build-33: "start start start start
    /// start"); DISTINCT rather than consecutive-only so filler between the
    /// repeats ("start um start") doesn't inflate the count either.
    private static func contentTokens(_ tokens: [String], language: CommandLanguage) -> Set<String> {
        let filler = VoiceCommandLexicon.fillerWords(for: language)
        return Set(tokens.filter { !filler.contains($0) })
    }

    /// STRICT skip: after stripping filler and collapsing duplicates, EXACTLY one
    /// distinct token remains and it is a confident skip variant. "skip" / "um
    /// skip please" / "skip skip" pass; "let's skip this one" (other content
    /// words remain) does not. The duplicate collapse matters MORE here than
    /// anywhere else: skip is the one command that may only fire from a final,
    /// and the final is precisely the transcript where repetitions merge.
    private static func matchesStrictSkip(tokens: [String], language: CommandLanguage) -> Bool {
        let content = contentTokens(tokens, language: language)
        guard content.count == 1, let token = content.first else { return false }
        let best = VoiceCommandLexicon.variants(for: .skip, language: language)
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
        var previous = Array(0 ... b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1 ... a.count {
            current[0] = i
            for j in 1 ... b.count {
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
