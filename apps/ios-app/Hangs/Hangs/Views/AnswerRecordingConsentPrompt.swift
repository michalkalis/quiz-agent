//
//  AnswerRecordingConsentPrompt.swift
//  Hangs
//
//  #197 (founder 2026-10-10): the one-time beta question about sending
//  answer recordings, asked on Home (the calm moment before a quiz, never
//  mid-question or during the voice flow). The rule of who is asked and when
//  lives in `AnswerRecordingConsent`.
//

import SwiftUI

struct AnswerRecordingConsentPrompt: ViewModifier {
    @State private var isPresented = false

    let isOnHome: Bool

    func body(content: Content) -> some View {
        content
            .onAppear(perform: askIfDue)
            .onChange(of: isOnHome) { askIfDue() }
            .alert("Help improve speech recognition", isPresented: $isPresented) {
                Button("Yes") { AnswerRecordingConsent.record(consented: true) }
                Button("No", role: .cancel) { AnswerRecordingConsent.record(consented: false) }
            } message: {
                Text("Send your answer recordings to the developer? Test version only. You can change this anytime in Settings.")
            }
    }

    private func askIfDue() {
        #if DEBUG
            if UITestSupport.isUITesting { return }
        #endif
        guard isOnHome, AnswerRecordingConsent.shouldAsk() else { return }
        isPresented = true
    }
}
