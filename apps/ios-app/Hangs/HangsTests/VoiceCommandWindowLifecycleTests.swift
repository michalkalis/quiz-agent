//
//  VoiceCommandWindowLifecycleTests.swift
//  HangsTests
//
//  Listening-window teardown (SilenceDetectionService+Drain). Old field runs
//  had results arriving after the window closed; `stopListening` cancelled
//  the recognizer, so a command said just before the close was discarded.
//  Teardown now finalizes what was already heard, never longer than a fixed
//  budget, and a drained final may reach only the next window on the same
//  screen. SpeechAnalyzer cannot run on the Simulator, so these pin the rules
//  through the pure seams; the analyzer calls themselves still need a device.
//

import Clocks
import Foundation
@testable import Hangs
import os
import Speech
import Testing

@Suite("Listening window teardown — bounded finalize, narrow redelivery")
@MainActor
struct VoiceCommandWindowLifecycleTests {
    // MARK: - Bounded finalize

    /// WHY: a result already on its way is kept only if teardown waits for it.
    @Test("a finalize that completes in time is the outcome, nothing is cancelled")
    func finalizeInTime() async {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let outcome = await SilenceDetectionService.finishWithinDeadline(
            clock: AnyClock(TestClock()), budget: .milliseconds(800),
            finalize: {}, cancel: { cancelled.withLock { $0 = true } }
        )
        #expect(outcome == .finalized)
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(cancelled.withLock { $0 } == false)
    }

    /// WHY: the next window waits for a drain. An analyzer that never answers
    /// must not hold it longer than the budget — teardown can never hang.
    @Test("a finalize that never returns is cut off at the budget and cancelled")
    func finalizeThatHangs() async {
        let clock = TestClock()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let decided = OSAllocatedUnfairLock<DrainOutcome?>(initialState: nil)
        let drain = Task {
            let outcome = await SilenceDetectionService.finishWithinDeadline(
                clock: AnyClock(clock), budget: .milliseconds(800),
                finalize: { try await Task.sleep(for: .seconds(3600)) },
                cancel: { cancelled.withLock { $0 = true } }
            )
            decided.withLock { $0 = outcome }
        }
        await clock.advance(by: .milliseconds(799))
        for _ in 0 ..< 20 {
            await Task.yield()
        }
        #expect(decided.withLock { $0 } == nil, "decided before the budget ran out")

        await clock.advance(by: .milliseconds(1))
        await drain.value
        #expect(decided.withLock { $0 } == .timedOut)
        for _ in 0 ..< 50 where !cancelled.withLock({ $0 }) {
            await Task.yield()
        }
        #expect(cancelled.withLock { $0 }, "a stuck analysis is cancelled")
    }

    @Test("a finalize that throws is cancelled, not waited for")
    func finalizeThatThrows() async {
        struct Broken: Error {}
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let outcome = await SilenceDetectionService.finishWithinDeadline(
            clock: AnyClock(TestClock()), budget: .milliseconds(800),
            finalize: { throw Broken() }, cancel: { cancelled.withLock { $0 = true } }
        )
        #expect(outcome == .failed)
        for _ in 0 ..< 50 where !cancelled.withLock({ $0 }) {
            await Task.yield()
        }
        #expect(cancelled.withLock { $0 })
    }

    // MARK: - Redelivery rule

    /// WHY: a drained final is the driver's command only for the window it
    /// was said in. On another screen it would act out of context — the tail
    /// of an answer recording landing on the answer sheet would count as a
    /// new answer, a question-screen "nie" would re-record on the sheet.
    @Test("only the same screen, the same recognizer and a fresh final are redelivered")
    func redeliveryRule() async {
        let clock = TestClock()
        let any = AnyClock(clock)
        let final = DrainedFinal(
            transcript: CommandTranscript(text: "preskoč", isFinal: true),
            screen: .question, localeIdentifier: "sk_SK", at: any.now
        )
        #expect(SilenceDetectionService.redelivers(final, to: .question, localeIdentifier: "sk_SK", now: any.now))
        #expect(!SilenceDetectionService.redelivers(final, to: .confirmation, localeIdentifier: "sk_SK", now: any.now))
        #expect(!SilenceDetectionService.redelivers(final, to: nil, localeIdentifier: "sk_SK", now: any.now))
        #expect(!SilenceDetectionService.redelivers(final, to: .question, localeIdentifier: "cs_CZ", now: any.now))

        await clock.advance(by: .milliseconds(1500))
        #expect(SilenceDetectionService.redelivers(final, to: .question, localeIdentifier: "sk_SK", now: any.now))
        await clock.advance(by: .milliseconds(1))
        #expect(
            !SilenceDetectionService.redelivers(final, to: .question, localeIdentifier: "sk_SK", now: any.now),
            "a final older than the max age belongs to a moment already past"
        )
    }

    // MARK: - Service wiring

    /// WHY: results of a window already torn down must never reach the live
    /// consumer directly — only through the redelivery rule.
    @Test("a stopped window's final waits for the next window on its screen")
    func drainedFinalReachesTheNextWindowOnly() async {
        let clock = TestClock()
        let service = SilenceDetectionService(clock: AnyClock(clock))
        service.setCommandScreen(.question)
        let stopped = service.listeningWindow
        service.stopListening() // no engine: only the window moves on

        service.handleEngineTranscript(CommandTranscript(text: "preskoč", isFinal: true), window: stopped)
        service.endDrain(.finalized, screen: .question, locale: service.transcriberEngine.locale.identifier, startedAt: AnyClock(clock).now)

        var next = service.makeCommandTranscriptStream().makeAsyncIterator()
        #expect(await next.next()?.text == "preskoč")
    }

    @Test("a stopped window's final is dropped when the next window is another screen")
    func drainedFinalIsDroppedElsewhere() async {
        let clock = TestClock()
        let service = SilenceDetectionService(clock: AnyClock(clock))
        service.setCommandScreen(.question)
        let stopped = service.listeningWindow
        service.stopListening()
        service.handleEngineTranscript(CommandTranscript(text: "nie", isFinal: true), window: stopped)
        service.endDrain(.finalized, screen: .question, locale: service.transcriberEngine.locale.identifier, startedAt: AnyClock(clock).now)

        service.setCommandScreen(.confirmation)
        var next = service.makeCommandTranscriptStream().makeAsyncIterator()
        service.handleEngineTranscript(CommandTranscript(text: "áno", isFinal: true), window: service.listeningWindow)
        #expect(await next.next()?.text == "áno", "the drained 'nie' must not re-record on the sheet")

        // And it does not wait for a later window either.
        service.setCommandScreen(.question)
        var later = service.makeCommandTranscriptStream().makeAsyncIterator()
        service.handleEngineTranscript(CommandTranscript(text: "zopakuj", isFinal: true), window: service.listeningWindow)
        #expect(await later.next()?.text == "zopakuj")
    }

    /// WHY: what the next window's analyzer loads is what decides how long
    /// the first command takes after every question read.
    @Test("analyzers keep their models for the next window")
    func modelsLingerAcrossWindows() {
        #expect(SilenceDetectionService.analyzerOptions.modelRetention == .lingering)
    }
}
