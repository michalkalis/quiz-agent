//
//  CarQuizApp.swift
//  CarQuiz
//
//  Voice-first trivia quiz app for hands-free use while driving
//

import Sentry
import SwiftUI

@main
struct CarQuizApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Skip Sentry on simulator — only real-device debug + release builds report.
        // Simulator runs are noisy (hot reloads, repeated launches) and would burn through quota.
        guard !Config.isSimulator, !Config.sentryDSN.isEmpty else { return }

        SentrySDK.start { options in
            options.dsn = Config.sentryDSN
            options.environment = Config.environmentName.lowercased()
            options.releaseName = Self.releaseIdentifier
            options.enableAutoSessionTracking = true
            options.tracesSampleRate = Config.isDebug ? 1.0 : 0.1

            options.attachScreenshot = true
            options.attachViewHierarchy = true
            options.enableFileIOTracing = true
            options.maxBreadcrumbs = 200

            options.sendDefaultPii = false
            options.beforeSend = Self.scrubEvent

            // Structured Logs (experimental in sentry-cocoa 8.x; moves to options.enableLogs in 9.0)
            options.experimental.enableLogs = true

            // Shake-to-report user feedback. Audio-input transcription is TODO — see memory.
            options.configureUserFeedback = { config in
                config.useShakeGesture = true
                config.showFormForScreenshots = true
            }

            #if DEBUG
            options.debug = false // set to true to troubleshoot Sentry setup
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .environmentObject(appState)
        }
    }

    /// Release identifier in `<bundle-id>@<version>+<build>` form, matching `sentry-cli releases` dSYM upload format.
    private static var releaseIdentifier: String {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.carquiz"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(bundleId)@\(version)+\(build)"
    }

    /// Remove free-form user speech (STT transcripts, typed answers) from events before they leave the device.
    /// Keep metadata (length, confidence) — strip raw text.
    /// `nonisolated` because `beforeSend` is called on Sentry's internal queue, not MainActor.
    nonisolated private static func scrubEvent(_ event: Event) -> Event? {
        let sensitiveKeys: Set<String> = ["transcript", "input_text", "user_text", "answer_text", "spoken_text"]

        if var extra = event.extra {
            for key in sensitiveKeys where extra[key] != nil {
                extra[key] = "[REDACTED]"
            }
            event.extra = extra
        }

        if let crumbs = event.breadcrumbs {
            for crumb in crumbs {
                guard var data = crumb.data else { continue }
                var mutated = false
                for key in sensitiveKeys where data[key] != nil {
                    data[key] = "[REDACTED]"
                    mutated = true
                }
                if mutated { crumb.data = data }
            }
        }

        return event
    }
}
