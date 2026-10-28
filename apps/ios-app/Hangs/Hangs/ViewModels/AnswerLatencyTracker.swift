//
//  AnswerLatencyTracker.swift
//  Hangs
//
//  #213.1: `answer_submitted.latency_ms` — how long the player took to start
//  answering. The window opens when they can first answer (the question read
//  aloud has ended; with read-aloud off, when the question appeared) and ends
//  at speech onset for a voice answer whose capture measured one, else at the
//  submit moment. Time spent paused is cut out. Time comes from the injected
//  clock, never wall time.
//
//  Unknown start = no number: a tap that lands mid-read (the window has not
//  opened) and a retry (the first try already consumed the window) report
//  nothing rather than a misleading figure.
//

import Clocks
import Foundation

@MainActor
final class AnswerLatencyTracker {
    private let clock: AnyClock<Duration>
    private var questionId: String?
    private var openedAt: AnyClock<Duration>.Instant?
    private var pausedSince: AnyClock<Duration>.Instant?
    private var pausedTotal: Duration = .zero
    private var speechOnset: AnyClock<Duration>.Instant?

    init(clock: AnyClock<Duration>) {
        self.clock = clock
    }

    /// The player can now answer `questionId`. Idempotent per question: the
    /// think timer is also re-armed after a pause or replay.
    func openWindow(questionId: String?) {
        guard let questionId, !(self.questionId == questionId && openedAt != nil) else { return }
        self.questionId = questionId
        openedAt = clock.now
        pausedSince = nil
        pausedTotal = .zero
        speechOnset = nil
    }

    func setPaused(_ paused: Bool) {
        guard openedAt != nil else { return }
        if paused {
            if pausedSince == nil { pausedSince = clock.now }
        } else if let since = pausedSince {
            pausedTotal += since.duration(to: clock.now)
            pausedSince = nil
        }
    }

    /// A finished recording: speech began `durationMs - firstSpeechMs` before now.
    func noteSpeechOnset(durationMs: Int, firstSpeechMs: Int?) {
        guard let firstSpeechMs else { return }
        speechOnset = clock.now.advanced(by: .milliseconds(firstSpeechMs - durationMs))
    }

    /// The latency of the answer being submitted, or nil when unknown. Closes
    /// the window: it measures the first attempt only.
    func consumeLatencyMs(questionId: String?, isRetry: Bool, voice: Bool) -> Int? {
        setPaused(false)
        defer { openedAt = nil; speechOnset = nil }
        guard !isRetry, questionId != nil, questionId == self.questionId, let openedAt else { return nil }
        let end = voice ? (speechOnset ?? clock.now) : clock.now
        let active = openedAt.duration(to: end) - pausedTotal
        return max(0, Int(active / .milliseconds(1)))
    }
}
