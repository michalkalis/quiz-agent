//
//  RecordingCoordinator+ReadBackEcho.swift
//  Hangs
//
//  Car test 2026-10-30 (TestFlight build 81): the answer sheet heard its own
//  read-back. Car speakers on Bluetooth media run without echo cancellation
//  (#185 route-aware voice processing) and keep sounding after the phone has
//  finished the clip, so the sheet's listener (#185 5.1: a non-command is a
//  new answer) caught the read-back. The upload came back as the same answer,
//  which was read back again and heard again: the sheet reopened until a tap.
//
//  Two layers keep the app's voice from being an answer:
//   1. the command listener strips the read-back's words before deciding
//      (`VoiceCommandCoordinator.echoGuardText`) — an echo is noise, and a
//      "confirm" said over it is a confirm;
//   2. the upload's transcript loses the read-back's words at its start
//      (here) — the recognizer can mishear the echo, the answer
//      transcription rarely does.
//

import Foundation

extension RecordingCoordinator {
    /// `transcript` without its leading words that the sheet just read back
    /// ("Capitalism. Confirm." after reading "Capitalism" → "Confirm."). Empty
    /// when every word is the read-back's; unchanged when none is. Only the
    /// start is stripped: the echo is what the mic hears first.
    static func strippingEchoedAnswer(_ transcript: String, readBack: String, language: CommandLanguage) -> String {
        let echoed = Set(VoiceCommandMatcher.normalize(readBack, language: language).split(separator: " "))
        let words = transcript.split(whereSeparator: \.isWhitespace)
        let firstHeard = words.firstIndex { word in
            !VoiceCommandMatcher.normalize(String(word), language: language)
                .split(separator: " ").allSatisfy { echoed.contains($0) }
        }
        guard let firstHeard else { return "" }
        guard firstHeard != words.startIndex else { return transcript }
        return words[firstHeard...].joined(separator: " ")
    }

    /// The upload was only the read-back: the answer stands as it was, not
    /// read again (that read is what looped), and the sheet listens again.
    func keepAnswerAfterEcho(_ replacement: SpokenReplacement) {
        attemptLedger.record(.network, "sheetAnswer.echo")
        SentryLog.info("sheet heard its own read-back — answer kept", category: .audio)
        restorePreviousAnswer(replacement, readBack: false)
        armConfirmationCountdown()
    }

    /// The upload was the read-back's echo followed by a new answer: only the
    /// new words are the answer. The server graded the merged text, so the
    /// grade is dropped and confirming re-grades the new words.
    func presentAnswerAfterEcho(_ answer: String) {
        attemptLedger.record(.network, "sheetAnswer.echoStripped")
        pendingResponse = nil
        presentVoiceTranscript(answer)
    }

    // MARK: - The line said before the mic opened (#243.4)

    /// TF drive 2026-11-23 (phone mic): "Skús to znova. Parmezán." — the tail
    /// of the app's retry hint in front of the answer. The transcript loses a
    /// leading run of `recordingEchoLine` before it is graded; only the run is
    /// the app's. `true` = handled here (shown without the run, or no answer).
    func handleSpokenLineEcho(in transcript: String, owner: AttemptID) -> Bool {
        guard let line = recordingEchoLine else { return false }
        let language = CommandLanguage.forQuizLanguage(currentSession()?.language ?? settings().language)
        let heard = Self.strippingSpokenLineEcho(transcript, line: line, language: language)
        guard heard != transcript else { return false }
        guard !heard.isEmpty else {
            // Only the app was heard: no answer. Silence, not a misunderstanding
            // — the hint again would be heard again.
            attemptLedger.record(.network, "voiceSubmit.echoOnly")
            handleTranscriptionFailure(owner: owner, heardSpeech: false)
            return true
        }
        attemptLedger.record(.network, "voiceSubmit.echoStripped")
        // The server graded the merged text: confirming re-grades the answer.
        pendingResponse = nil
        presentVoiceTranscript(heard, owner: owner)
        return true
    }

    /// `transcript` without its leading run of `line`'s words. A run counts
    /// when it is two or more consecutive words of the line, the whole line, or
    /// the line's last word of four letters or more — a lone short word ("A",
    /// "to") may well be the answer. The run's first word may be the end of a
    /// line word (the mic caught "…podarilo" of "nepodarilo"). Empty when the
    /// whole transcript is the run; unchanged when there is none.
    static func strippingSpokenLineEcho(_ transcript: String, line: String, language: CommandLanguage) -> String {
        func keys(_ text: String) -> [String] {
            TranscriptFolding.fold(text).split(separator: " ")
                .map { VoiceCommandMatcher.phoneticFold(String($0), language: language) }
        }
        let lineKeys = keys(line)
        guard !lineKeys.isEmpty else { return transcript }
        let words = transcript.split(whereSeparator: \.isWhitespace)
        var prefix: [String] = []
        var stripped = 0
        for (index, word) in words.enumerated() {
            prefix += keys(String(word))
            guard !prefix.isEmpty else { continue }
            guard containsRun(lineKeys, prefix) else { break }
            let isLastWord = prefix.count == 1 && prefix[0] == lineKeys.last && prefix[0].count >= 4
            if prefix.count >= 2 || prefix == lineKeys || isLastWord { stripped = index + 1 }
        }
        guard stripped > 0 else { return transcript }
        return words[stripped...].joined(separator: " ")
    }

    private static func containsRun(_ haystack: [String], _ run: [String]) -> Bool {
        guard run.count <= haystack.count else { return false }
        return (0 ... haystack.count - run.count).contains { start in
            let first = haystack[start]
            guard first == run[0] || (run[0].count >= 4 && first.hasSuffix(run[0])) else { return false }
            return Array(haystack[start + 1 ..< start + run.count]) == Array(run.dropFirst())
        }
    }
}
