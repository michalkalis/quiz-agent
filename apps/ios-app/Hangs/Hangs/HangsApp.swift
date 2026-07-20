//
//  HangsApp.swift
//  Hangs
//
//  Voice-first trivia quiz app for hands-free use while driving
//

import os
import Sentry
import SwiftUI

@main
struct HangsApp: App {
    @StateObject private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

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

            // #109: our own in-app feedback UI (shake + Settings row → FeedbackView)
            // replaces Sentry's shake widget so there is exactly one feedback flow.
            // Sentry stays for crashes only; its useShakeGesture/showFormForScreenshots
            // are intentionally left at their defaults (off).

            #if DEBUG
            options.debug = false // set to true to troubleshoot Sentry setup
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .environmentObject(appState)
                .onOpenURL { url in
                    Logger.quiz.info("📱 onOpenURL: \(url.absoluteString, privacy: .public)")
                    #if DEBUG
                    Task { @MainActor in
                        await UITestSupport.handleTestURL(url)
                    }
                    #endif
                }
                // Wake the auto-stopped Fly machine while the user is still on
                // the start screen, so the first quiz request doesn't eat the
                // ~10s cold start (min_machines_running stays 0 = no fixed cost).
                .task {
                    await Self.warmUpBackend()
                }
                // Mic-in-background fix: UIBackgroundModes audio keeps TTS
                // playing while driving, but the mic INPUT must never survive
                // backgrounding. Route phase changes to the quiz view model,
                // which tears down input on .background and re-arms on .active.
                .onChange(of: scenePhase) { _, newPhase in
                    appState.quizViewModel?.handleScenePhase(newPhase)
                }
        }
    }

    /// Fire-and-forget health ping; result is irrelevant, the side effect (machine boot) is the point.
    private static func warmUpBackend() async {
        guard let url = URL(string: Config.apiBaseURLWithVersion + "/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Release identifier in `<bundle-id>@<version>+<build>` form, matching `sentry-cli releases` dSYM upload format.
    private static var releaseIdentifier: String {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.missinghue.hangs"
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
