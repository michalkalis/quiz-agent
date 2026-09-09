//
//  HangsQuizToolbar.swift
//  Hangs
//
//  #173 Track B, variant A3 (founder locked 2026-09-07): the quiz screen's
//  chrome is the NATIVE navigation toolbar, identical for MCQ, voice and image
//  questions — ✕ leading, [mute][pause] trailing, then a ⋯ menu.
//
//  Why native: the two hand-rolled top rows (`mcqTopRow` / `HangsQuizTopBar`)
//  had drifted apart (MCQ had no settings gear), and the TestFlight rating +
//  feedback chips were an absolutely positioned overlay that collided with the
//  MCQ category label at a fixed 96pt inset (the founder's 2026-09-07 report).
//  A toolbar lays itself out, so nothing can overlap anything.
//
//  HIG "More" rule: only the controls a driver reaches for mid-question live in
//  the bar; everything else is one tap away under the ellipsis.
//
//  These are plain Views, not `ToolbarContent`: the call site wraps them in
//  `ToolbarItem`/`ToolbarItemGroup`, and they stay directly inspectable in tests.
//

import SwiftUI

/// Mute toggle — pink while muted so a silenced quiz is visible at a glance
/// (the #173 finding 1a root cause: a mute carried over from a previous run).
struct QuizMuteToolbarButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
        }
        .tint(isMuted ? Theme.Hangs.Colors.pink : Theme.Hangs.Colors.ink)
        .accessibilityLabel(isMuted ? Text("Unmute") : Text("Mute"))
        .accessibilityIdentifier("question.mute")
    }
}

/// Quiz-level pause — available in EVERY state now (#173 founder decision 4),
/// not just on the answer confirmation sheet it used to be trapped on.
struct QuizPauseToolbarButton: View {
    let isPaused: Bool
    /// #174: "pause" is a voice command (confirmation sheet) — badge the glyph.
    var showsVoiceGlyph: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                .overlay(alignment: .bottomTrailing) {
                    if showsVoiceGlyph, !isPaused {
                        VoiceGlyph(size: 7)
                            .offset(x: 5, y: 3)
                    }
                }
        }
        .tint(isPaused ? Theme.Hangs.Colors.blue : Theme.Hangs.Colors.ink)
        .accessibilityLabel(isPaused ? Text("Continue") : Text("Pause"))
        .accessibilityIdentifier("question.pause")
    }
}

/// The ⋯ menu: everything that is NOT a mid-question control. Feedback and
/// Rate question keep their TestFlight/Debug gating — nil closure = no row,
/// which is exactly what an App Store build passes.
struct QuizOverflowMenu: View {
    let onSettings: () -> Void
    var onFeedback: (() -> Void)?
    var onRateQuestion: (() -> Void)?

    var body: some View {
        Menu {
            Button(action: onSettings) {
                Label("Settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("question.settingsButton")

            if let onFeedback {
                Button(action: onFeedback) {
                    Label("Send feedback", systemImage: "exclamationmark.bubble")
                }
                .accessibilityIdentifier("feedback.entry")
            }

            if let onRateQuestion {
                Button(action: onRateQuestion) {
                    Label("Rate question", systemImage: "star.bubble")
                }
                .accessibilityIdentifier("rating.entry")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .tint(Theme.Hangs.Colors.ink)
        .accessibilityLabel(Text("More"))
        .accessibilityIdentifier("question.moreMenu")
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            Theme.Hangs.Colors.bg
                .ignoresSafeArea()
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        QuizMuteToolbarButton(isMuted: true) {}
                        QuizPauseToolbarButton(isPaused: false) {}
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        QuizOverflowMenu(onSettings: {}, onFeedback: {}, onRateQuestion: {})
                    }
                }
        }
    }
#endif
