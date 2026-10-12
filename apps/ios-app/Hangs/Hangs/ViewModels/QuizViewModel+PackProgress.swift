//
//  QuizViewModel+PackProgress.swift
//  Hangs
//
//  #200 (TF test 2026-10-12): a custom pack remembers which of its questions
//  this phone has played. Each play continues with the next unplayed ones, a
//  pack played through asks before it starts over, and every "again" path
//  replays the same pack instead of falling back to the shared library.
//
//  Pack questions live in their own ledger (`PersistenceStoreProtocol`), marked
//  when a question is on screen, never at prefetch. They no longer enter the
//  global history, so resetting that history leaves pack progress alone.
//

import Foundation
import os

extension QuizViewModel {
    /// Play Again, Try Again and the spoken "znova": the same kind of set as
    /// the latest start, the same pack when it was one. These used to start
    /// the shared library, which dropped a driver out of the pack they chose.
    @discardableResult
    func playAgain() -> Task<Void, Never> {
        beginQuizStart(pack: activePack)
    }

    /// "Start over" on the played-through alert: forget the pack's progress,
    /// then start it from the top. Nil when another start got there first
    /// (the Home voice window stays open under the alert): the progress is
    /// kept, because the start that would replay it cannot run.
    @discardableResult
    func restartPack(_ pack: PackPlay) -> Task<Void, Never>? {
        packRestartOffer = nil
        guard !isStarting, quizState.validTransitions.contains(QuizState.startingQuiz.label) else { return nil }
        persistenceStore.clearPackProgress(packId: pack.packId)
        return beginQuizStart(pack: pack)
    }

    /// "Cancel" — and the setter behind the alert's `isPresented` binding.
    func dismissPackRestartOffer() {
        packRestartOffer = nil
    }

    /// Questions of `packId` this phone has played ("10 / 30").
    func playedQuestionCount(inPack packId: String) -> Int {
        persistenceStore.playedPackQuestionIds(packId: packId).count
    }

    /// Asks before starting a pack the phone has played through. Checked
    /// before the start leaves the current screen, so Cancel keeps the player
    /// where they were (Home, or the end of the round).
    func offerRestartIfPlayedThrough(_ pack: PackPlay) -> Bool {
        guard let count = pack.questionCount, count > 0,
              playedQuestionCount(inPack: pack.packId) >= count,
              quizState.validTransitions.contains(QuizState.startingQuiz.label)
        else { return false }
        Logger.quiz.info("📦 Pack \(pack.packId, privacy: .public) played through (\(count, privacy: .public)), offering a restart")
        packRestartOffer = pack
        return true
    }

    /// Safety net: the server's `pack_exhausted` for a pack the phone thought
    /// was not played through (its count was off). With progress on record
    /// the same offer applies and the start returns to Home. Without any,
    /// nothing was played here, so it is a real failure and stays one.
    func offerRestartAfterServerRanOut(_ pack: PackPlay) -> Bool {
        guard playedQuestionCount(inPack: pack.packId) > 0 else { return false }
        Logger.quiz.info("📦 Server ran out of pack \(pack.packId, privacy: .public), offering a restart")
        currentSession = nil
        persistenceStore.clearSession()
        transition(to: .idle)
        packRestartOffer = pack
        return true
    }

    /// A library question joins the global history as soon as it is served
    /// (prefetch included, as before); a pack question never does.
    func recordServedLibraryQuestion(_ question: Question?) {
        guard activePack == nil, let id = question?.id else { return }
        persistenceStore.addQuestionId(id)
    }

    /// A pack question counts as played once it is on screen.
    func markPackQuestionShown(_ question: Question?) {
        guard let packId = activePackId, let id = question?.id else { return }
        persistenceStore.markPackQuestionPlayed(id, packId: packId)
    }
}
