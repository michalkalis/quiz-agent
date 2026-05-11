//
//  HangsButtonInspectorTests.swift
//  HangsTests
//
//  Task 4.3 (issue #31): ViewInspector assertions for the three Hangs button
//  style variants — HangsPrimaryButton, HangsSecondaryButton, HangsGhostButton.
//
//  Swift 6 / AnyView note (audit A2-7): .find(text:) and
//  .find(ViewType.Image.self, where:) use breadth-first traversal and
//  sidestep most explicit chain issues. .implicitAnyView() is added where
//  an explicit navigation step is required.
//

import Foundation
import Testing
import ViewInspector
@testable import Hangs

// MARK: - HangsPrimaryButton

@Suite("HangsPrimaryButton ViewInspector Tests")
@MainActor
struct HangsPrimaryButtonInspectorTests {

    @Test("Title text appears in rendered tree")
    func titleTextAppearsInRenderedTree() async throws {
        let view = HangsPrimaryButton(title: "Start Quiz") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Start Quiz")
            }
        }
    }

    @Test("Leading icon SF Symbol appears when icon is provided")
    func leadingIconAppearsWhenProvided() async throws {
        let view = HangsPrimaryButton(title: "Play", icon: "play.fill") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "play.fill"
                })
            }
        }
    }

    @Test("Trailing icon SF Symbol appears when trailingIcon is provided")
    func trailingIconAppearsWhenProvided() async throws {
        let view = HangsPrimaryButton(title: "Next", trailingIcon: "arrow.right") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "arrow.right"
                })
            }
        }
    }

    @Test("No icon appears when neither icon nor trailingIcon is provided")
    func noIconAppearsWithoutIconParam() async throws {
        let view = HangsPrimaryButton(title: "Continue") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(ViewType.Image.self, where: { _ in true })
            }
        }
    }

    @Test("Tapping primary button invokes the action closure")
    func tappingInvokesAction() async throws {
        var tapped = false
        let view = HangsPrimaryButton(title: "Go") { tapped = true }
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(ViewType.Button.self).tap()
            #expect(tapped == true)
        }
    }

    @Test("Loading state shows ProgressView instead of icon text")
    func loadingStateShowsProgressView() async throws {
        let view = HangsPrimaryButton(title: "Loading", isLoading: true) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.ProgressView.self)
            }
        }
    }
}

// MARK: - HangsSecondaryButton

@Suite("HangsSecondaryButton ViewInspector Tests")
@MainActor
struct HangsSecondaryButtonInspectorTests {

    @Test("Title text appears in rendered tree")
    func titleTextAppearsInRenderedTree() async throws {
        let view = HangsSecondaryButton(title: "Home") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Home")
            }
        }
    }

    @Test("Leading icon appears when provided")
    func leadingIconAppearsWhenProvided() async throws {
        let view = HangsSecondaryButton(title: "Home", icon: "house.fill") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "house.fill"
                })
            }
        }
    }

    @Test("Tapping secondary button invokes the action closure")
    func tappingInvokesAction() async throws {
        var tapped = false
        let view = HangsSecondaryButton(title: "Home") { tapped = true }
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(ViewType.Button.self).tap()
            #expect(tapped == true)
        }
    }
}

// MARK: - HangsGhostButton

@Suite("HangsGhostButton ViewInspector Tests")
@MainActor
struct HangsGhostButtonInspectorTests {

    @Test("Title text appears in rendered tree")
    func titleTextAppearsInRenderedTree() async throws {
        let view = HangsGhostButton(title: "Why is this correct?") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Why is this correct?")
            }
        }
    }

    @Test("Leading icon appears when provided")
    func leadingIconAppearsWhenProvided() async throws {
        let view = HangsGhostButton(title: "Info", icon: "book.closed") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "book.closed"
                })
            }
        }
    }

    @Test("Tapping ghost button invokes the action closure")
    func tappingInvokesAction() async throws {
        var tapped = false
        let view = HangsGhostButton(title: "Skip") { tapped = true }
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            try tree.find(ViewType.Button.self).tap()
            #expect(tapped == true)
        }
    }

    @Test("Ghost button absent of icon when none provided")
    func noIconWhenNoneProvided() async throws {
        let view = HangsGhostButton(title: "Skip") {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(ViewType.Image.self, where: { _ in true })
            }
        }
    }
}
