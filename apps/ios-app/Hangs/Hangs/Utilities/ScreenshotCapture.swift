//
//  ScreenshotCapture.swift
//  Hangs
//
//  Renders the current key window into a UIImage for the in-app feedback
//  attachment (#109). Must be called BEFORE the feedback sheet presents so the
//  capture shows the screen the user is reporting about, not the sheet itself.
//

import UIKit

@MainActor
enum ScreenshotCapture {
    /// Render the foreground key window into a PNG-ready `UIImage`.
    /// `afterScreenUpdates: false` snapshots the *current* frame — passing `true`
    /// would flush a pending layout pass and could capture a presenting sheet.
    static func captureKeyWindow() -> UIImage? {
        guard let window = keyWindow() else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
            // Fall back to any window if none is flagged key (rare, e.g. mid-transition).
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first
    }
}
