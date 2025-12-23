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
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    Task {
                        // Request microphone permission on first launch
                        _ = await appState.audioService.requestMicrophonePermission()
                    }
                }
        }
    }
}
