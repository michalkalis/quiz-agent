//
//  VoiceCommandCoordinator+Reading.swift
//  Hangs
//
//  #208.7 (founder, TF 2026-10-16): voice commands while the question is read.
//  The bar showed "repeat" / "skip" during the read, yet the listener was down
//  for all of it, so the driver said the command, nothing happened, and he said
//  it again once the read ended. Now, when an echo-cancelling engine is already
//  live as the read begins (voice processing armed: the iPhone speaker/receiver
//  or a hands-free call route), it simply stays up through the read. It is
//  never STARTED for a read: arming voice processing under a playing clip would
//  switch the session mode mid-sentence. Everything else keeps today's
//  behaviour: the listener comes down for the read and back up after it.
//
//  What listening over the app's own voice costs, and what pays for it:
//  • the echo guard — words of the read (question + options) are stripped from
//    a transcript before matching, so leaked echo can neither fire a command
//    nor light a cue; it sticks to an utterance that began during the read,
//    whose final can land after it ended;
//  • only repeat / skip route during the read ("start" would open the
//    answer mic over the rest of the sentence);
//  • the speech detector is suspended for the read (`suspendSpeechEdges`):
//    the app's voice is not the driver's, and must not hold it "speaking".
//
//  Rollback: `VoicePipelineFlags.commandsDuringReading` (Settings › voice
//  diagnostics).
//

import Clocks
import Foundation

/// #208.7: the numbers one command utterance is logged with — counts and
/// levels only, never what was said (no-raw-speech rule, Logging.swift).
struct CommandUtteranceLog {
    var onsetAt: AnyClock<Duration>.Instant?
    var onsetLevelDb: Float?
    var noiseFloorDb: Float?
    var peakDb: Float?
    var firstTranscriptMs: Int?
    var matchMs: Int?
    var transcripts = 0
    var echoDrops = 0
    var duringRead = false

    var isEmpty: Bool { transcripts == 0 && echoDrops == 0 }
}

extension VoiceCommandCoordinator {
    /// The question screen's commands while the question is read. "start" is
    /// left out on purpose — it opens the answer mic over the sentence. (Pause
    /// is not spoken on the question screen at all — the toolbar's, #171 D.)
    static let readingCommands: Set<VoiceCommand> = [.repeatQuestion, .skip]

    /// The listener is up through the read in progress.
    var listensThroughQuestionRead: Bool {
        listenerKeptThroughRead && isReadingQuestionAloud()
    }

    /// Whether this transcript is judged as one heard over the read.
    var isUnderEchoGuard: Bool {
        listensThroughQuestionRead || utteranceBeganDuringRead
    }

    // MARK: - Read lifecycle (called by the read paths in AudioDeviceState)

    /// A question read is about to play. Keeps the live listener up through it
    /// when that is safe (see the file header) and returns whether it did; on
    /// `false` the caller tears the listener down exactly as before.
    func beginQuestionRead() -> Bool {
        let vpArmed = silenceDetectionService.voiceProcessingStatus?.armed == true
        let flag = commandsDuringReadingEnabled()
        let keep = flag
            && commandCapturePhase == .listening
            && silenceDetectionService.isListening
            && vpArmed
        listenerKeptThroughRead = keep
        if keep {
            // A volatile parked just before the read must not fire under it
            // ("start" would open the answer mic over the sentence).
            cancelVolatileSettle()
            silenceDetectionService.suspendSpeechEdges(true)
            // Speech edges stop here; a hearing / processing cue lit before
            // the read has nothing left to report.
            noteFinalProcessedForFeedback()
        }
        // Only with the switch on: off, every read would log `kept=false`.
        if flag {
            SentryLog.info("voice cmd read listener", category: .voice, attributes: [
                "kept": keep, "flag": flag,
                "live": silenceDetectionService.isListening, "vpArmed": vpArmed,
            ])
        }
        return keep
    }

    /// The read ended (or was cut). The detector judges speech again.
    func endQuestionRead() {
        guard listenerKeptThroughRead else { return }
        listenerKeptThroughRead = false
        silenceDetectionService.suspendSpeechEdges(false)
    }

    // MARK: - Echo guard

    /// What the app itself just said into this window, or `nil` when no echo
    /// guard applies: the question over a kept read, or — car test 2026-10-30 —
    /// the answer the sheet read back. Car speakers on Bluetooth media have no
    /// echo cancellation and sound on after the phone finished the clip, so the
    /// sheet's listener heard "Skipped." and took it for a new answer.
    func echoGuardText(on screen: VoiceCommandScreen) -> String? {
        if isUnderEchoGuard { return textBeingRead() }
        return screen == .confirmation ? answerReadBack() : nil
    }

    /// `normalized` with every word of `read` removed, or `nil` when no read
    /// text is known. Stripping rather than rejecting the whole transcript:
    /// with leaky echo cancellation a command said over the read arrives
    /// merged into echo residue ("…ktorý napísal preskoč").
    func strippingReadWords(_ normalized: String, read: String?) -> String? {
        guard let read, !read.isEmpty else { return nil }
        let readWords = Set(VoiceCommandMatcher.normalize(read, language: commandLanguage).split(separator: " "))
        // Cancel words survive: a question with "nie" in it must not swallow
        // the "nie" that aborts a skip said over the read.
        return normalized.split(separator: " ")
            .filter { !readWords.contains($0) || VoiceCommandLexicon.isCancelWord(String($0), language: commandLanguage) }
            .joined(separator: " ")
    }

    // MARK: - Utterance log

    /// The VAD heard speech begin: the anchor of this utterance's timings.
    func noteUtteranceOnset(levelDb: Float, noiseFloorDb: Float?) {
        // A blip before it that never produced a transcript is not an utterance.
        if utteranceLog.isEmpty { utteranceLog = CommandUtteranceLog() }
        guard utteranceLog.onsetAt == nil else { return }
        utteranceLog.onsetAt = clock.now
        utteranceLog.onsetLevelDb = levelDb
        utteranceLog.noiseFloorDb = noiseFloorDb
    }

    func noteUtterancePeak(_ peakDb: Float) {
        utteranceLog.peakDb = max(utteranceLog.peakDb ?? peakDb, peakDb)
    }

    /// A transcript arrived (counted whether or not it survives the guard).
    func noteUtteranceTranscript() {
        if utteranceLog.onsetAt == nil { utteranceLog.onsetAt = clock.now }
        utteranceLog.transcripts += 1
        if utteranceLog.firstTranscriptMs == nil { utteranceLog.firstTranscriptMs = msSinceUtteranceOnset() }
        if isUnderEchoGuard { utteranceLog.duringRead = true }
    }

    func noteUtteranceMatched() {
        if utteranceLog.matchMs == nil { utteranceLog.matchMs = msSinceUtteranceOnset() }
    }

    private func msSinceUtteranceOnset() -> Int? {
        utteranceLog.onsetAt.map { Int(($0.duration(to: clock.now).timeInterval * 1000).rounded()) }
    }

    /// Log the utterance once, at its end (its final, or a torn-down
    /// listener), then start a fresh record. Utterances that never produced a
    /// transcript (a cough, a door) are not logged.
    func flushUtteranceLog(screen: VoiceCommandScreen?, outcome: String) {
        defer { utteranceLog = CommandUtteranceLog() }
        guard !utteranceLog.isEmpty else { return }
        let log = utteranceLog
        SentryLog.info("voice cmd utterance", category: .voice, attributes: [
            "screen": screen.map { String(describing: $0) } ?? "none",
            "outcome": log.matchMs != nil ? "matched" : outcome,
            "peakDb": Double(log.peakDb ?? -160),
            "onsetDb": Double(log.onsetLevelDb ?? -160),
            "noiseFloorDb": Double(log.noiseFloorDb ?? -160),
            "onsetToFirstTranscriptMs": log.firstTranscriptMs ?? -1,
            "onsetToMatchMs": log.matchMs ?? -1,
            "transcripts": log.transcripts,
            "echoGuardDrops": log.echoDrops,
            "duringRead": log.duringRead,
            "ttsPlaying": isPlayingTTS(),
            "vpArmed": silenceDetectionService.voiceProcessingStatus?.armed == true,
        ])
    }
}
