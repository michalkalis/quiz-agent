//
//  ProgressBarViewInspectorTests.swift
//  HangsTests
//
//  Task 4.3 (issue #31): ViewInspector assertions for ProgressBarView —
//  progress-fraction binding reflected in the rendered percentage Text,
//  custom title, showPercentage flag, and structural GeometryReader presence.
//
//  GeometryReader note: the fill width is computed inside a GeometryReader
//  and is not directly inspectable as a value. The percentage Text
//  ("0%" / "50%" / "100%") is asserted instead — this confirms the binding
//  reached the rendered tree. The structural presence of the GeometryReader
//  itself is asserted separately.
//

import Foundation
import Testing
import ViewInspector
@testable import Hangs

@Suite("ProgressBarView ViewInspector Tests")
@MainActor
struct ProgressBarViewInspectorTests {

    @Test("Zero progress renders 0% text and title")
    func zeroProgressRendersZeroPercentText() async throws {
        let view = ProgressBarView(progress: 0.0)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "0%")
            }
            #expect(throws: Never.self) {
                try tree.find(text: "Question Progress")
            }
        }
    }

    @Test("Half progress renders 50% text")
    func halfProgressRendersFiftyPercentText() async throws {
        let view = ProgressBarView(progress: 0.5)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "50%")
            }
        }
    }

    @Test("Full progress renders 100% text")
    func fullProgressRendersHundredPercentText() async throws {
        let view = ProgressBarView(progress: 1.0)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "100%")
            }
        }
    }

    @Test("Custom title appears in rendered tree")
    func customTitleAppearsInRenderedTree() async throws {
        let view = ProgressBarView(progress: 0.7, title: "Completion")
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Completion")
            }
            #expect(throws: Never.self) {
                try tree.find(text: "70%")
            }
        }
    }

    @Test("showPercentage false hides percentage text")
    func showPercentageFalseHidesPercentageText() async throws {
        let view = ProgressBarView(progress: 1.0, showPercentage: false)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(text: "100%")
            }
            #expect(throws: Never.self) {
                try tree.find(text: "Question Progress")
            }
        }
    }

    @Test("GeometryReader track structure is present in rendered tree")
    func geometryReaderTrackStructureIsPresent() async throws {
        let view = ProgressBarView(progress: 0.5)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(ViewType.GeometryReader.self)
            }
        }
    }
}
