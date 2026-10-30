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
}
