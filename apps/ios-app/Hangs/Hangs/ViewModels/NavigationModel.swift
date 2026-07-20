//
//  NavigationModel.swift
//  Hangs
//
//  Issue #111 (navigation as owned state). Owns the pushed-stack path for
//  ContentView's single root NavigationStack, replacing the old notification
//  broadcast + view-identity-reset bridge. Teardown is reactive: it
//  clears whenever `quizState` ENTERS `.startingQuiz` (not merely "leaves
//  .idle" — see issue-111 gate note 1), which makes it structurally impossible
//  to start a quiz (voice, error-retry, or any of the 9 `startNewQuiz` sites)
//  without also tearing the pushed stack down.
//

import Combine
import SwiftUI

/// The pushed-stack routes on ContentView's root `NavigationStack`. A plain
/// value enum (no associated values) so it stays `Hashable` for
/// `NavigationStack(path:)` / `NavigationLink(value:)` — see issue-111 gate
/// note 2. OrderPack→OrderProgress is the one push that stays local
/// `navigationDestination(isPresented:)` (OrderProgress observes OrderPack's
/// live, reference-typed view model, which cannot live in a Hashable enum).
enum AppRoute: Hashable {
    case settings
    case orderPack
    case myPacks
    #if DEBUG
        case debugLog
    #endif
}

/// Owns the navigation surface for ContentView's root stack: the pushed
/// `NavigationPath` and the belt-and-braces `isPresented` binding for the
/// OrderPack→OrderProgress child (issue-111 gate note 2). Both are cleared
/// atomically the moment `quizState` enters `.startingQuiz`, so a quiz start
/// from anywhere — voice "start" over a pushed stack, error-retry, or a
/// button — always tears the stack down; there is no per-call-site teardown
/// to forget.
@MainActor
final class NavigationModel: ObservableObject {
    @Published var path = NavigationPath()
    @Published var orderProgressPresented = false

    /// Resets the whole nav surface — path + the OrderProgress `isPresented`
    /// child — in one step, so no in-between state is ever observable.
    func clearAll() {
        path = NavigationPath()
        orderProgressPresented = false
    }

    /// Reactive teardown seam: called from ContentView's
    /// `.onReceive(viewModel.$quizState)`. Clears iff `new` is
    /// `.startingQuiz` — the sole quiz-start transition, for every
    /// predecessor (`.idle` today; `.error` too once #110's retry transition
    /// lands). QuizState's Equatable compares cases only (associated values
    /// ignored), so plain `==` already matches `.error(...)` correctly here.
    func handleQuizStateChange(_ new: QuizState) {
        guard new == .startingQuiz else { return }
        clearAll()
    }
}
