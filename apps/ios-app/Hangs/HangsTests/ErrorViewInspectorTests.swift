//
//  ErrorViewInspectorTests.swift
//  HangsTests
//
//  #52 task 52.14 — Error screen (Fwafe frame) bound to AppErrorModel (52.7).
//
//  Why these tests matter:
//  - The "OOPS" headline and model.title must both render so regressions that
//    drop one of the two text layers fail immediately.
//  - CTA selection driven by model.retryAction is the semantic contract of 52.7:
//    a .retryOperation model must show "Try Again"; a .goHome model must not.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import UIKit
import ViewInspector

// MARK: - Helpers

@MainActor
private func makeErrorView(
    title: String = "Niečo sa pokazilo",
    description: String = "Skontroluj pripojenie a skús to znova.",
    retryAction: AppErrorRetryAction = .retryOperation
) -> ErrorView {
    let vm = QuizViewModel(
        networkService: MockNetworkService(),
        audioService: MockAudioService(),
        persistenceStore: MockPersistenceStore()
    )
    let model = AppErrorModel(title: title, description: description, retryAction: retryAction)
    return ErrorView(viewModel: vm, model: model)
}

// MARK: - Structural: "OOPS" + title + description render

@MainActor
@Suite("ErrorView — structure")
struct ErrorViewStructureTests {
    @Test("'OOPS' headline always renders")
    func oopsHeadlineRenders() async throws {
        let view = makeErrorView()
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "OOPS") }
        }
    }

    @Test("model.title renders below OOPS")
    func modelTitleRenders() async throws {
        let view = makeErrorView(title: "Čas vypršal")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Čas vypršal") }
        }
    }

    @Test("model.description renders as body text")
    func modelDescriptionRenders() async throws {
        let view = makeErrorView(description: "Server odpovedal príliš pomaly.")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Server odpovedal príliš pomaly.") }
        }
    }
}

// MARK: - CTA selection driven by model.retryAction

@MainActor
@Suite("ErrorView — CTA selection")
struct ErrorViewCTATests {
    @Test(".retryOperation shows 'Try Again' CTA")
    func retryOperationShowsTryAgain() async throws {
        let view = makeErrorView(retryAction: .retryOperation)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Try Again") }
        }
    }

    @Test(".retryOperation also shows secondary 'Go Home' button")
    func retryOperationShowsGoHome() async throws {
        let view = makeErrorView(retryAction: .retryOperation)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Go Home") }
        }
    }

    @Test(".goHome shows 'Go Home' but not 'Try Again'")
    func goHomeHidesTryAgain() async throws {
        let view = makeErrorView(retryAction: .goHome)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Go Home") }
            #expect(throws: (any Error).self) { try tree.find(text: "Try Again") }
        }
    }

    @Test(".dismiss shows 'Dismiss' but not 'Try Again'")
    func dismissShowsDismissButton() async throws {
        let view = makeErrorView(retryAction: .dismiss)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(text: "Dismiss") }
            #expect(throws: (any Error).self) { try tree.find(text: "Try Again") }
        }
    }
}
