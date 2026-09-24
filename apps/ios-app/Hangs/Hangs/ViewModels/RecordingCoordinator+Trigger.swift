//
//  RecordingCoordinator+Trigger.swift
//  Hangs
//
//  #185 (founder 2026-09-24): what a recording start does when the question is
//  still being read out. Car test 2026-09-23: 0.86 s after a silent skip the mic
//  opened on the next question WHILE it was being read, and the driver's
//  repeated answer to the previous question landed on it. The founder's rule:
//
//  - an explicit "answer now" (tap, spoken start, re-record) STOPS the read-out
//    and records immediately — the driver chose to answer;
//  - the hands-free start (think/answer countdown, foreground resume) WAITS for
//    the read-out to finish — nobody asked to cut the question off.
//
//  Either way the recording is a new attempt of the question on screen
//  (`startRecording` begins it after the transition). This file is the one
//  place the policy lives, so changing it is a one-line change.
//

import Clocks
import Foundation

/// Who asked for the recording.
enum RecordingTrigger: String, Sendable {
    case tap
    case voiceCommand
    case autoRecord
    case bargeIn
    case rerecord
    case emptyAnswerRetry
    case foregroundResume

    /// Founder rule above: only the hands-free starts wait for the read-out.
    var waitsForQuestionReadOut: Bool {
        switch self {
        case .autoRecord, .foregroundResume: true
        case .tap, .voiceCommand, .bargeIn, .rerecord, .emptyAnswerRetry: false
        }
    }
}

extension RecordingCoordinator {
    enum QuestionReadOutResolution: Equatable {
        /// Nothing is being read (or the read-out has finished): record.
        case proceed
        /// A manual start during the read-out: stop it, then record.
        case interrupt
        /// The wait ended without the question still being the one to answer.
        case abandon
    }

    /// Resolve a recording start against a question read-out in progress.
    /// Polls the injected clock (tests drive it) while the read plays; the
    /// caller's task owns the wait, so cancelling that task (a tap, a skip, a
    /// teardown) ends it.
    func resolveQuestionReadOut(for trigger: RecordingTrigger) async -> QuestionReadOutResolution {
        guard isPlayingQuestionTTS() else { return .proceed }
        guard trigger.waitsForQuestionReadOut else { return .interrupt }

        let owner = attemptLedger.current
        attemptLedger.record(.timer, "recording.waitsForReadOut", trigger.rawValue)
        while isPlayingQuestionTTS() {
            do {
                try await clock.sleep(for: .milliseconds(100))
            } catch {
                return .abandon
            }
            guard quizState() == .askingQuestion,
                  attemptLedger.ownsQuestion(owner, "recording.waitForReadOut")
            else { return .abandon }
        }
        return .proceed
    }
}
