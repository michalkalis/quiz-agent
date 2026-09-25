//
//  QuizSequenceRun+Checks.swift
//  HangsTests
//
//  #186 step 2 — the quiz invariants, checked after every burst of inputs,
//  after every move of the clock and while the final minute runs out; plus the
//  ones only the doubles can see as they happen (what was submitted, what cut
//  the question read-out short) and every state change as it is made.
//

import Foundation
@testable import Hangs

extension QuizSequenceRun {
    // MARK: - Event-driven checks (called by the doubles and the state stream)

    func stateWillChange(to new: QuizState) {
        let old = lastState
        lastState = new
        if !old.validTransitions.contains(new.label) {
            fail("illegal transition", "\(old.label)→\(new.label)")
        }
    }

    func textSubmitted(_ request: SequenceNetwork.Request) {
        let input = (request.input ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty {
            fail("empty answer submitted", "question \(request.questionId ?? "-")")
        } else if input == "skip" {
            let question = request.questionId ?? "-"
            if let intents = skipIntents[question], intents > 0 {
                skipIntents[question] = intents - 1
                sentSkips[question] = request.attempt
                skipsSubmitted.append(question)
            } else if sentSkips[question] != request.attempt {
                fail("question skipped without the driver asking", "question \(question)")
            }
        }
    }

    /// Founder rule (#185, 2026-09-24): while its question is still open,
    /// only the driver stops the question read-out — a tap, a spoken start,
    /// speech over it, or a phone call. The hands-free start waits for it, and
    /// nothing else may end it before it is heard. (Once the question is
    /// answered, moving on may cut it.)
    func clipCutShort(_ clip: SequenceAudio.Clip, _ cut: SequenceAudio.Cut, question: String?) {
        guard clip == .question, !burstHasDriver, context != .interruption else { return }
        let sameQuestion = question == vm.currentQuestion?.id
        // The mic opening moves the state to `.recording` first, so only the
        // question identity says whose read-out it cut.
        let stillOpen = sameQuestion && vm.quizState == .askingQuestion
        let why = "\(cut.rawValue) while \(context.map(\.description) ?? "time passed")"
        switch cut {
        case .recordingPrep where sameQuestion:
            if vm.isPlayingQuestionTTS || !knownBug(.readOutFlagLost) {
                fail("mic opened over the question read-out without the driver", why)
            }
        case .callerCancelled where stillOpen:
            fail("question read-out ended before it was heard", why)
        case .stopped where stillOpen, .superseded where stillOpen:
            fail("question read-out cut short without the driver", why)
        default:
            break
        }
    }

    /// Bugs this harness found OUTSIDE step 1 / #185 track B, reported with
    /// #186 step 2 and not fixed there. Counted, not failed, so the harness
    /// keeps guarding everything else; `QUIZ_SEQUENCE_STRICT=1` fails on them.
    /// Delete a case with its fix.
    enum KnownBug: String, CaseIterable {
        /// A replay tap during the initial read-out stops it; the initial
        /// read's tail then clears `isPlayingQuestionTTS` while the REPLAY is
        /// playing and arms the think countdown, so the hands-free start sees
        /// no read-out and opens the mic over the replay.
        case readOutFlagLost
    }

    private func knownBug(_ bug: KnownBug) -> Bool {
        guard allowsKnownBug else { return false }
        knownBugHits[bug, default: 0] += 1
        return true
    }

    func fail(_ invariant: String, _ detail: String) {
        guard violation == nil else { return }
        violation = Violation(invariant: invariant, detail: detail, atMs: nowMs)
        recorderAtViolation = recorder.dump(last: 60)
    }

    // MARK: - State checks at every quiet point

    func check() {
        guard violation == nil else { return }
        checkLedger()
        checkConfirmationSheet()
        checkResults()
        // #149 F3: the Voice-commands switch is a CAPTURE switch — with it off
        // the mic is live only while an answer is being recorded.
        if !vm.settings.voiceCommandsEnabled, silence.isListening, vm.quizState != .recording {
            fail("mic live with voice commands off", "state \(vm.quizState.label)")
        }
        checkEpisodes()
    }

    /// Step 1's own invariants (sheet only in `.processing` and only for the
    /// current attempt; a result only for the current question) — evaluated
    /// here at every quiet point, not only where the app happens to call them.
    private func checkLedger() {
        vm.verifyQuizInvariants(after: "sequenceHarness")
        let found = vm.attemptLedger.invariantViolations
        if found.count > seenLedgerViolations {
            fail("step 1 invariant: \(found[seenLedgerViolations])", "state \(vm.quizState.label)")
        }
        seenLedgerViolations = found.count
    }

    /// A transcript on the sheet must be the one the CURRENT attempt's upload
    /// returned, for the question on screen — the car-test bug in its own words.
    private func checkConfirmationSheet() {
        guard vm.showAnswerConfirmation else { return }
        let question = vm.currentQuestion?.id ?? "-"
        let seen = "\(question) " + (vm.noAnswerCaptured ? "(nothing heard)" : vm.transcribedAnswer)
        if sheetsSeen.last != seen { sheetsSeen.append(seen) }
        guard !vm.noAnswerCaptured, !isSheetEmpty else { return }
        guard let request = network.voiceRequest(forTranscript: vm.transcribedAnswer) else {
            fail("sheet shows a transcript no upload returned", vm.transcribedAnswer)
            return
        }
        if request.attempt != vm.currentAttempt {
            fail("sheet shows another attempt's transcript", "\(request.attempt) on \(vm.currentAttempt)")
        } else if request.questionId != vm.currentQuestion?.id {
            fail("sheet shows another question's transcript", "\(request.questionId ?? "-") on \(question)")
        }
    }

    /// A result belongs to the question it is shown for, was graded for that
    /// question, and is never a graded empty answer (an empty answer may only
    /// ever end as the driver's skip).
    private func checkResults() {
        if case let .showingResult(question, evaluation) = vm.quizState {
            if question.id != vm.currentQuestion?.id {
                fail("result shown for another question", "\(question.id) on \(vm.currentQuestion?.id ?? "-")")
            } else if evaluation.questionId != question.id {
                fail("result graded for another question", "\(evaluation.questionId ?? "-") shown on \(question.id)")
            }
        }
        for entry in vm.recapEntries.dropFirst(seenRecapEntries) {
            let question = entry.sourceUrl.map { String($0.split(separator: "/").last ?? "") } ?? "-"
            let answer = entry.userAnswerDisplay ?? ""
            if entry.explanation != SequenceQuiz.gradedNote(question) {
                fail("result graded for another question", "\(entry.explanation ?? "-") recorded for \(question)")
            } else if answer.isEmpty, !entry.wasSkipped {
                fail("empty answer produced a result", "question \(question)")
            } else if let request = network.voiceRequest(forTranscript: answer), request.questionId != question {
                fail("answer recorded on another question", "\(answer) of \(request.questionId ?? "-") on \(question)")
            }
        }
        seenRecapEntries = vm.recapEntries.count
    }

    /// States the quiz may not REST in, each with the bound that ends it on
    /// its own (dead-air cap, submit timeout / stall watchdog, auto-confirm,
    /// auto-advance). Keyed by attempt, so a new episode starts a new clock.
    private func checkEpisodes() {
        var active: [String: (invariant: String, boundMs: Int)] = [:]
        let attempt = vm.currentAttempt.description
        switch vm.quizState {
        case .recording:
            active["recording \(attempt)"] = ("stuck recording", 16000)
        case .skipping:
            active["skipping \(attempt)"] = ("stuck skipping", 40000)
        case .startingQuiz:
            active["startingQuiz"] = ("stuck starting the quiz", 5000)
        case .processing where !isSheetUp:
            active["processing \(attempt)"] = ("stuck processing with no sheet", 40000)
        case .processing where vm.showAnswerConfirmation && !vm.noAnswerCaptured && !isSheetEmpty
            && vm.settings.autoConfirmEnabled && !vm.isPaused && !vm.isEditingTranscript:
            active["sheet \(attempt) \(vm.transcribedAnswer)"] = ("confirmation sheet never auto-confirmed", 12000)
        case .showingResult where !vm.isPaused:
            active["result \(vm.resultQuestion?.id ?? "-")"] = ("result never auto-advanced", 15000)
        default:
            break
        }
        episodes = episodes.filter { active[$0.key] != nil }
        for (key, rule) in active {
            let since = episodes[key] ?? nowMs
            episodes[key] = since
            if nowMs - since > rule.boundMs {
                fail(rule.invariant, "\(key) for \((nowMs - since) / 1000) s")
            }
        }
    }
}
