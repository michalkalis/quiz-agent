//
//  RecordingCoordinator+ReadBackEcho.swift
//  Hangs
//
//  Car test 2026-10-30 (TestFlight build 81): the answer sheet heard its own
//  read-back. Car speakers on Bluetooth media run without echo cancellation
//  (#185 route-aware voice processing) and keep sounding after the phone has
//  finished the clip, so the sheet's listener caught the read-back. The
//  command listener strips the read-back's words before deciding
//  (`VoiceCommandCoordinator.echoGuardText`): an echo is noise, and an "again"
//  said over it is an "again". (#243.5: speech on the sheet is no longer
//  uploaded as a new answer, so the upload-side layer went with it.)
//
//  #243.4: the same idea for the answer itself — the app line spoken right
//  before the mic opened is stripped from the front of the transcript.
//

import Foundation

extension RecordingCoordinator {
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
