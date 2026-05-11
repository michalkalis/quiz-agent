//
//  MicButtonInspectorTests.swift
//  HangsTests
//
//  Task 4.3 (issue #31): ViewInspector assertions for MicButton's three
//  states (idle / recording / processing) — state-driven SF Symbol icon
//  and accessibility label.
//
//  Swift 6 / AnyView note (audit A2-7): .find(ViewType.Image.self, where:)
//  uses breadth-first traversal and sidesteps explicit chain issues.
//
//  Icon visibility note: the Image inside MicButton is .accessibilityHidden(true).
//  ViewInspector still locates it via .actualImage().name(); accessibility
//  visibility does not block ViewInspector traversal.
//

import Foundation
import Testing
import ViewInspector
@testable import Hangs

@Suite("MicButton ViewInspector Tests")
@MainActor
struct MicButtonInspectorTests {

    // MARK: - Idle

    @Test("Idle state renders mic.fill icon")
    func idleStateRendersMicFillIcon() async throws {
        let view = MicButton(state: .idle) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "mic.fill"
                })
            }
        }
    }

    @Test("Idle state accessibility label is Start recording answer")
    func idleStateHasCorrectAccessibilityLabel() async throws {
        let view = MicButton(state: .idle) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let button = try tree.find(ViewType.Button.self)
            let label = try button.accessibilityLabel()
            #expect(try label.string() == "Start recording answer")
        }
    }

    // MARK: - Recording

    @Test("Recording state renders stop.circle.fill icon")
    func recordingStateRendersStopCircleFillIcon() async throws {
        let view = MicButton(state: .recording) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "stop.circle.fill"
                })
            }
        }
    }

    @Test("Recording state accessibility label is Stop recording")
    func recordingStateHasCorrectAccessibilityLabel() async throws {
        let view = MicButton(state: .recording) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let button = try tree.find(ViewType.Button.self)
            let label = try button.accessibilityLabel()
            #expect(try label.string() == "Stop recording")
        }
    }

    // MARK: - Processing

    @Test("Processing state renders waveform icon")
    func processingStateRendersWaveformIcon() async throws {
        let view = MicButton(state: .processing) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.Image.self, where: {
                    try $0.actualImage().name() == "waveform"
                })
            }
        }
    }

    @Test("Processing state accessibility label is Processing answer")
    func processingStateHasCorrectAccessibilityLabel() async throws {
        let view = MicButton(state: .processing) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let button = try tree.find(ViewType.Button.self)
            let label = try button.accessibilityLabel()
            #expect(try label.string() == "Processing answer")
        }
    }

    // MARK: - State distinctiveness

    /// All three states must render different SF Symbols — guarantees the
    /// iconName switch is not collapsed into a single shared name.
    @Test("All three states render different SF Symbol icons")
    func allThreeStatesRenderDistinctIcons() async throws {
        var icons: [String] = []

        for state in [MicButton.State.idle, .recording, .processing] {
            let view = MicButton(state: state) {}
            try await ViewHosting.host(view) {
                let tree = try view.inspect()
                if let img = try? tree.find(ViewType.Image.self, where: { _ in true }),
                   let name = try? img.actualImage().name() {
                    icons.append(name)
                }
            }
        }

        let uniqueIcons = Set(icons)
        #expect(uniqueIcons.count == 3)
        #expect(uniqueIcons.contains("mic.fill"))
        #expect(uniqueIcons.contains("stop.circle.fill"))
        #expect(uniqueIcons.contains("waveform"))
    }
}
