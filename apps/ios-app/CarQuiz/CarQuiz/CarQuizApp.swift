//
//  CarQuizApp.swift
//  CarQuiz
//
//  Voice-first trivia quiz app for hands-free use while driving
//

import SwiftUI
@main
struct CarQuizApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .environmentObject(appState)
        }
    }
}
