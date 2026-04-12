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
        SentrySDK.start { options in
            options.dsn = Config.sentryDSN
            options.environment = Config.environmentName.lowercased()
            options.enableAutoSessionTracking = true
            options.tracesSampleRate = Config.isDebug ? 1.0 : 0.1
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
}
