//
//  VoiceCommandCoordinator+WindowReport.swift
//  Hangs
//
//  The `voice_command_window` analytics event: one report per listening
//  window, so the on-device-or-cloud decision for sk / cs / uk rests on
//  numbers — per language and engine, windows that heard nothing, utterances
//  that matched no command, results after the window closed, and the time
//  to the first result. The Sentry logs above it are sampled and quota'd;
//  this is the countable record. Counts only, never what was said.
//

import Clocks
import Foundation

/// The running counts of the window in progress (see `CommandWindowReport`).
struct CommandWindowStats {
    let screen: VoiceCommandScreen
    let openedAt: AnyClock<Duration>.Instant
    var transcripts = 0
    var matched = 0
    var unmatched = 0
    var late = 0
    var cutOff = 0
    var firstTranscriptMs: Int?
    /// An utterance has results but no final yet.
    var utteranceInProgress = false
}

extension VoiceCommandCoordinator {
    /// The listener went live on `screen`. A re-arm on the same screen (window
    /// syncs, route restarts) is the same window for the driver; a new screen
    /// closes the old one first.
    func openCommandWindowReport(on screen: VoiceCommandScreen) {
        if commandWindowStats?.screen == screen { return }
        closeCommandWindowReport()
        commandWindowStats = CommandWindowStats(screen: screen, openedAt: clock.now)
    }

    /// One recognizer result. Once an answer recording has the shared engine,
    /// the window is over: what it hears is the answer, neither a command nor
    /// late, so the window is reported as it stood.
    func noteWindowTranscript(windowOpen: Bool, isFinal: Bool) {
        if isRecordingActive {
            closeCommandWindowReport()
            return
        }
        if windowOpen { transcriptsHeard += 1 }
        guard var stats = commandWindowStats else { return }
        stats.utteranceInProgress = !isFinal
        if windowOpen {
            stats.transcripts += 1
            if stats.firstTranscriptMs == nil {
                stats.firstTranscriptMs = Int((stats.openedAt.duration(to: clock.now).timeInterval * 1000).rounded())
            }
        } else {
            stats.late += 1
        }
        commandWindowStats = stats
    }

    func noteWindowCommandMatched() {
        commandWindowStats?.matched += 1
    }

    func noteWindowUtteranceUnmatched() {
        commandWindowStats?.unmatched += 1
    }

    /// The window is over (listener down, or the recording took the engine):
    /// report it once. An utterance still waiting for its final is cut off.
    func closeCommandWindowReport() {
        guard var stats = commandWindowStats else { return }
        commandWindowStats = nil
        if stats.utteranceInProgress { stats.cutOff += 1 }
        let code = currentSession()?.language ?? settings().language
        trackAnalytics(.voiceCommandWindow(CommandWindowReport(
            engine: CommandEngineSelection.forQuizLanguage(code).engineTag,
            language: commandLanguage.rawValue,
            screen: String(describing: stats.screen),
            transcripts: stats.transcripts,
            matched: stats.matched,
            unmatched: stats.unmatched,
            late: stats.late,
            cutOff: stats.cutOff,
            firstTranscriptMs: stats.firstTranscriptMs
        )))
    }
}
