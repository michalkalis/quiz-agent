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
//  #184 (car-noise field test, Slovak): commands only worked when SHOUTED, so
//  scoring gained Jaro-Winkler — it rewards a shared PREFIX, which is exactly
//  the failure shape of a half-heard command ("znov" for "znova"), where
//  Levenshtein's length penalty rejects it. CONFLICT with #119: JW would also
//  score "star"→"start" at ~0.96 and reopen the one-edit-noise hole the
//  volatile floor was tuned on field data to close. DECISION — the combined
//  score `max(levenshtein, jaroWinkler)` applies to FINALS ONLY; a volatile
//  hypothesis keeps Levenshtein alone, AND the JW term applies only to a
//  TRUNCATION — a shorter token that still carries the variant's head. Every
//  clause is load-bearing: without them "skib" burns a question, "nekst"
//  advances the quiz, and the Czech backchannel "no" re-records the answer.
//  See `score`.
//
//  #185 (car test 2026-09-23, founder 5.3): "nie, znova" was two content
//  words and never matched. A multi-word utterance now matches when EVERY
//  content word is itself a word of the SAME command (`agreeingCommand`) — the
//  #119 protection is intact because conversation always carries a word that
//  is not a command. Two-word phrases ("ešte raz") are joined into one token by
//  `normalize`, words that open sentences ("nie") act on finals only, and a
//  word that is a command on this screen is never stripped as filler there.
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
    /// collapsed) for an utterance to be read as ONE command word. ONE,
    /// because every word in this grammar is one word — see the gate in `match`.
    static let maxContentTokens = 1
    /// #185: upper bound for an utterance made only of words of ONE command
    /// ("nie, zle, znova") — see `agreeingCommand`.
    static let maxAgreeingTokens = 3

    /// Resolve `transcript` to the single command valid on `screen`, or `nil`
    /// when there is no confident, unambiguous match (caller re-listens).
    ///
    /// - Parameters:
    ///   - transcript: a transcript from the command recognizer — since #119 a
    ///     volatile hypothesis as well as a final (see `isFinal`).
    ///   - screen: the current screen — bounds which commands are considered.
    ///   - isFinal: whether this is a finalized transcript. A volatile hypothesis
    ///     is scored against the stricter `volatileConfidenceFloor`.
    ///   - language: the command grammar language (#120). The app passes the
    ///     quiz language (#175); the `.english` default is the tests' pin.
    static func match(
        transcript: String, on screen: VoiceCommandScreen, isFinal: Bool = true,
        language: CommandLanguage = .english
    ) -> VoiceCommand? {
        let normalized = normalize(transcript, language: language)
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
        let content = contentTokens(tokens, language: language, on: screen)
        // Filler only is never a command (#185: a lone "ešte" must not score as
        // a cut-off "ešte raz"), and only content words are scored.
        guard !content.isEmpty else { return nil }
        if content.count > maxContentTokens {
            return agreeingCommand(content, on: screen, isFinal: isFinal, language: language)
        }
        return matchOneWord(Array(content), on: screen, isFinal: isFinal, language: language)
    }

    /// #185: several content words, each of which is on its own a confident
    /// match for the SAME command — "nie, znova", "áno, potvrď". Any word that
    /// is not a command, or two words that disagree ("áno, znova"), and the
    /// utterance is not a command.
    private static func agreeingCommand(
        _ content: Set<String>, on screen: VoiceCommandScreen, isFinal: Bool, language: CommandLanguage
    ) -> VoiceCommand? {
        guard content.count <= maxAgreeingTokens else { return nil }
        var agreed: VoiceCommand?
        for word in content.sorted() {
            guard let command = matchOneWord([word], on: screen, isFinal: isFinal, language: language),
                  agreed == nil || agreed == command else { return nil }
            agreed = command
        }
        return agreed
    }

    /// The pre-#185 matcher: an utterance with at most ONE content word.
    private static func matchOneWord(
        _ tokens: [String], on screen: VoiceCommandScreen, isFinal: Bool, language: CommandLanguage
    ) -> VoiceCommand? {
        let candidates = VoiceCommandLexicon.commands(on: screen)

        // Skip is strict whole-utterance — handled before (and excluded from) the
        // fuzzy token scan so it can never be triggered by a token buried in a
        // longer sentence.
        if candidates.contains(.skip),
           matchesStrictSkip(tokens: tokens, on: screen, language: language, isFinal: isFinal)
        {
            return .skip
        }

        // Fuzzy token scan over the remaining screen commands.
        var scores: [(command: VoiceCommand, score: Double)] = []
        for command in candidates where command != .skip {
            let variants = comparableVariants(for: command, on: screen, language: language, isFinal: isFinal)
            var best = 0.0
            for token in tokens {
                for variant in variants {
                    best = max(best, score(token, variant, isFinal: isFinal))
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
    ///
    /// `normalized` must already have come out of `normalize(_:language:)` for
    /// the SAME language — the filler set is compared after the same phonetic
    /// fold, so a mismatched normalization would silently stop stripping filler.
    static func hasContentTokens(
        _ normalized: String,
        language: CommandLanguage = .english
    ) -> Bool {
        let tokens = normalized.split(separator: " ").map(String.init)
        return !contentTokens(tokens, language: language).isEmpty
    }

    /// The DISTINCT content tokens of an utterance: filler stripped, duplicates
    /// collapsed. Duplicates collapse because a driver repeating an unanswered
    /// command is still saying ONE word (build-33: "start start start start
    /// start"); DISTINCT rather than consecutive-only so filler between the
    /// repeats ("start um start") doesn't inflate the count either. With a
    /// `screen`, that screen's command words are never filler (#185).
    private static func contentTokens(
        _ tokens: [String], language: CommandLanguage, on screen: VoiceCommandScreen? = nil
    ) -> Set<String> {
        // #184: the filler set is stored pre-folded but NOT phonetically folded,
        // so it goes through the same step the tokens did — otherwise a Slovak
        // filler could survive the fold and count as content.
        let words = screen.map { VoiceCommandLexicon.fillerWords(for: language, on: $0) }
            ?? VoiceCommandLexicon.fillerWords(for: language)
        let filler = Set(words.map { phoneticFold($0, language: language) })
        return Set(tokens.filter { !filler.contains($0) })
    }

    /// A command's lexicon variants on `screen` put through the SAME phonetic
    /// fold the transcript went through (#184). Variants are stored
    /// diacritic-folded but in dictionary spelling, so without this step a
    /// folded mishearing ("znovy" → "znovi") would be scored against an unfolded
    /// "znova" and the fold would buy nothing. A volatile never sees the
    /// sentence-opening words (#185 `finalOnlyVariants`).
    private static func comparableVariants(
        for command: VoiceCommand, on screen: VoiceCommandScreen, language: CommandLanguage, isFinal: Bool
    ) -> [String] {
        let finalOnly = isFinal ? [] : VoiceCommandLexicon.finalOnlyVariants(for: language)
        return VoiceCommandLexicon.variants(for: command, language: language, on: screen)
            .filter { !finalOnly.contains($0) }
            .map { phoneticFold($0, language: language) }
    }

    /// STRICT skip: after stripping filler and collapsing duplicates, EXACTLY one
    /// distinct token remains and it is a confident skip variant. "skip" / "um
    /// skip please" / "skip skip" pass; "let's skip this one" (other content
    /// words remain) does not. The duplicate collapse matters MORE here than
    /// anywhere else: skip is the one command that may only fire from a final,
    /// and the final is precisely the transcript where repetitions merge.
    private static func matchesStrictSkip(
        tokens: [String], on screen: VoiceCommandScreen, language: CommandLanguage, isFinal: Bool
    ) -> Bool {
        let content = contentTokens(tokens, language: language, on: screen)
        guard content.count == 1, let token = content.first else { return false }
        let best = comparableVariants(for: .skip, on: screen, language: language, isFinal: isFinal)
            .map { score(token, $0, isFinal: isFinal) }
            .max() ?? 0
        return best >= skipFloor
    }

    // MARK: - Scoring

    /// The score one token earns against one lexicon variant (#184).
    ///
    /// A FINAL takes `max(levenshtein, jaroWinkler)`, a VOLATILE Levenshtein
    /// alone — see the conflict note in the file header.
    ///
    /// AND the JW term only applies to a TRUNCATION: a token shorter than the
    /// variant that shares its first `truncationPrefix` characters. Both clauses
    /// are field-tuned guards, not tidiness:
    ///
    ///  • equal length — edit distance is already fair there, so JW is pure
    ///    loosening: it rates "skib"/"skip" 0.88 (burns a freemium question) and
    ///    "nekst"/"next" 0.83 (advances the quiz), the exact near-misses #119's
    ///    floors exist to reject;
    ///  • no shared prefix — JW's match term is `matches / token.count`, so a
    ///    SHORT token scores absurdly well against a long word that merely
    ///    contains its letters: the Czech backchannel "no" rates 0.80 against
    ///    "znovu" and would re-record the answer. A half-heard command loses its
    ///    TAIL, never its head, so requiring the head is what separates the two.
    static func score(_ token: String, _ variant: String, isFinal: Bool) -> Double {
        let levenshtein = similarity(token, variant)
        guard isFinal, isTruncation(token, of: variant) else { return levenshtein }
        return max(levenshtein, jaroWinkler(token, variant))
    }

    /// Leading characters a shortened token must share with a variant before it
    /// is treated as a truncation rather than a different word.
    static let truncationPrefix = 2

    /// Whether `token` looks like `variant` with its tail cut off.
    private static func isTruncation(_ token: String, of variant: String) -> Bool {
        guard token.count < variant.count, token.count >= truncationPrefix else { return false }
        return token.prefix(truncationPrefix) == variant.prefix(truncationPrefix)
    }

    /// Jaro-Winkler similarity in [0, 1] (standard scaling factor p = 0.1,
    /// common prefix capped at 4). Unlike edit distance it does not divide by
    /// the longer string's length, so a truncated word keeps most of its score.
    static func jaroWinkler(_ a: String, _ b: String) -> Double {
        let x = Array(a)
        let y = Array(b)
        if x.isEmpty, y.isEmpty { return 1.0 }
        guard !x.isEmpty, !y.isEmpty else { return 0.0 }

        let jaro = jaroSimilarity(x, y)
        guard jaro > 0 else { return 0.0 }

        var prefix = 0
        for index in 0 ..< min(4, min(x.count, y.count)) {
            if x[index] == y[index] { prefix += 1 } else { break }
        }
        return jaro + Double(prefix) * 0.1 * (1.0 - jaro)
    }

    /// The Jaro base score: matching characters within a half-length window,
    /// discounted by half the transpositions among them.
    private static func jaroSimilarity(_ x: [Character], _ y: [Character]) -> Double {
        if x == y { return 1.0 }
        let window = max(max(x.count, y.count) / 2 - 1, 0)
        var xMatched = [Bool](repeating: false, count: x.count)
        var yMatched = [Bool](repeating: false, count: y.count)
        var matches = 0

        for i in 0 ..< x.count {
            let lower = max(0, i - window)
            let upper = min(i + window + 1, y.count)
            guard lower < upper else { continue }
            for j in lower ..< upper where !yMatched[j] && x[i] == y[j] {
                xMatched[i] = true
                yMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0.0 }

        var transpositions = 0
        var k = 0
        for i in 0 ..< x.count where xMatched[i] {
            while !yMatched[k] { k += 1 }
            if x[i] != y[k] { transpositions += 1 }
            k += 1
        }
        let m = Double(matches)
        return (m / Double(x.count) + m / Double(y.count) + (m - Double(transpositions) / 2.0) / m) / 3.0
    }

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
    /// punctuation don't defeat matching), then — for Slovak/Czech only — apply
    /// the #184 phonetic fold, and join the #185 command phrases ("ešte raz")
    /// into one token.
    static func normalize(_ string: String, language: CommandLanguage = .english) -> String {
        let folded = string.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            scalars.append(CharacterSet.alphanumerics.contains(scalar) ? scalar : " ")
        }
        let tokens = String(scalars)
            .split(separator: " ")
            .map { phoneticFold(String($0), language: language) }
        return joinPhrases(tokens, language: language).joined(separator: " ")
    }

    /// Replace every run of a lexicon phrase's words with its single token.
    private static func joinPhrases(_ tokens: [String], language: CommandLanguage) -> [String] {
        let phrases = VoiceCommandLexicon.phrases(for: language).map { phrase in
            (words: phrase.words.map { phoneticFold($0, language: language) }, token: phrase.token)
        }
        var result: [String] = []
        var index = 0
        scan: while index < tokens.count {
            for phrase in phrases where tokens[index...].starts(with: phrase.words) {
                result.append(phrase.token)
                index += phrase.words.count
                continue scan
            }
            result.append(tokens[index])
            index += 1
        }
        return result
    }

    /// #184 Slovak/Czech phonetic fold: collapse the spelling distinctions a
    /// noisy on-device recognizer flips between but a speaker never hears
    /// (y/i, w/v, q/k, x/ks), then squash doubled letters. A mishearing
    /// ("znovy", "znnova") and the lexicon form then meet on one spelling
    /// instead of costing an edit each. ENGLISH IS LEFT ALONE — its command set
    /// was tuned on field data with no fold, and "y" carries meaning there
    /// ("retry" vs "retri" is not the failure we saw).
    static func phoneticFold(_ token: String, language: CommandLanguage) -> String {
        switch language {
        case .english: return token
        case .slovak, .czech: break
        }
        var result = ""
        var previous: Character?
        for character in token {
            let mapped: String
            switch character {
            case "y": mapped = "i"
            case "w": mapped = "v"
            case "q": mapped = "k"
            case "x": mapped = "ks"
            default: mapped = String(character)
            }
            for scalar in mapped {
                guard scalar != previous else { continue } // collapse runs
                result.append(scalar)
                previous = scalar
            }
        }
        return result
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
