//
//  HomeViewSnapshotTests.swift
//  HangsTests
//
//  Task 5 (issue #31): .dump snapshot baseline for HomeView.
//
//  Variant: idleWithStats
//  Uses QuizViewModel.preview (askingQuestion state, default settings).
//  Captures the structural presence of HangsHeroBlock, HangsCard (config card),
//  HangsPrimaryButton, and the home.startQuiz accessibility identifier.
//
//  Strategy: .dump only — text mirror of view struct tree. No image rendering.
//

import Foundation
import SnapshotTesting
import Testing
@testable import Hangs

@Suite("HomeView Snapshot Tests")
@MainActor
struct HomeViewSnapshotTests {

    /// HomeView in its default idle-with-stats state.
    /// Confirms that:
    ///   • HangsHeroBlock is present in the view tree
    ///   • HangsCard (config card) appears in the tree
    ///   • HangsPrimaryButton is present (the Start Quiz CTA)
    ///   • The accessibility identifier "home.startQuiz" appears in the dump
    @Test("Snapshot: idle state with stats and config card")
    func idleWithStats() async {
        let viewModel = QuizViewModel.preview
        let view = HomeView(viewModel: viewModel)
        assertSnapshot(of: view, as: .stableDump)
    }
}
