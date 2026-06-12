//
//  HangsSurfaceAdaptivityTests.swift
//  HangsTests
//
//  Issue #54 task 54.1 (dark mode broken): card surfaces hardcoded `Color.white`
//  instead of the adaptive `bgCard` token, producing white cards with near-white
//  `ink` text in dark mode (illegible while driving). These tests render the
//  actual primitives in dark mode and assert the surface pixel is dark — a
//  revert to `Color.white` turns the pixel white and fails the test, which a
//  structure-only inspector test cannot catch.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import UIKit

@MainActor
struct HangsSurfaceAdaptivityTests {
    /// Render the view at its natural size in the given appearance and return
    /// the relative luminance (0 black … 1 white) of the center pixel.
    private func centerLuminance(of content: some View, dark: Bool) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: content.environment(\.colorScheme, dark ? .dark : .light)
        )
        renderer.scale = 1
        let cgImage = try #require(renderer.cgImage, "render produced no image")
        let width = cgImage.width, height = cgImage.height
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        // Draw so the source center pixel lands in the 1×1 destination.
        context.draw(cgImage, in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        return (0.2126 * CGFloat(pixel[0]) + 0.7152 * CGFloat(pixel[1]) + 0.0722 * CGFloat(pixel[2])) / 255
    }

    /// bgCard dark = #1F1F22 (luminance ≈ 0.12); a white card is 1.0. The 0.5
    /// threshold separates "dark surface" from "light surface" robustly.
    private func assertSurfaceAdapts(
        _ content: some View, _ name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let darkLum = try centerLuminance(of: content, dark: true)
        #expect(darkLum < 0.5, "\(name) surface stays light in dark mode (luminance \(darkLum))",
                sourceLocation: sourceLocation)
        let lightLum = try centerLuminance(of: content, dark: false)
        #expect(lightLum > 0.5, "\(name) surface unexpectedly dark in light mode (luminance \(lightLum))",
                sourceLocation: sourceLocation)
    }

    @Test("HangsCard surface adapts to dark mode")
    func cardSurfaceAdapts() throws {
        try assertSurfaceAdapts(
            HangsCard { Color.clear.frame(width: 80, height: 80) },
            "HangsCard"
        )
    }

    @Test("HangsAnswerRow surface adapts to dark mode")
    func answerRowSurfaceAdapts() throws {
        // Empty label/value so the sampled center pixel is pure background.
        try assertSurfaceAdapts(
            HangsAnswerRow(label: "", value: "").frame(width: 200, height: 60),
            "HangsAnswerRow"
        )
    }

    @Test("HangsSecondaryButton pill adapts to dark mode")
    func secondaryButtonSurfaceAdapts() throws {
        try assertSurfaceAdapts(
            HangsSecondaryButton(title: " ") {}.frame(width: 200),
            "HangsSecondaryButton"
        )
    }
}
