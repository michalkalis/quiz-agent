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

/// #188 G9 (D9): the ONE quiz top bar, shared by the question and the result
/// screen. The result screen used to draw its own row (✕ + logo + "03 / 10"
/// counter) with the TestFlight chips floated over it, and at large text the
/// counter landed on the chips and the logo's dot wrapped. Now both screens put
/// sound and pause in the same place, and the counter lives in
/// `HangsQuizProgressHeader` under the bar, where it scales down instead.
///
/// ✕ leading; the mute + pause pill trailing (#179 D2); everything else under ⋯
/// — the HIG "More" rule (#173 decision 1).
///
/// A modifier rather than a `ToolbarContent` type on purpose: the items stay a
/// plain `TupleToolbarContent` on the screen's own `.toolbar`, which is the shape
/// the screens' toolbar tests and text contracts already walk.
extension View {
    func quizToolbar(
        isMuted: Bool,
        isPaused: Bool,
        isPauseEnabled: Bool,
        onClose: @escaping () -> Void,
        onMute: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onSettings: @escaping () -> Void,
        onFeedback: (() -> Void)? = nil,
        onRateQuestion: (() -> Void)? = nil
    ) -> some View {
        toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .tint(Theme.Hangs.Colors.ink)
                .accessibilityLabel(Text("Close quiz"))
                .accessibilityIdentifier("question.closeButton")
            }

            // #179 D2: one joined pill, not a group the system spacing spreads
            // into two unrelated buttons.
            ToolbarItem(placement: .topBarTrailing) {
                QuizControlPill(
                    isMuted: isMuted,
                    isPaused: isPaused,
                    isPauseEnabled: isPauseEnabled,
                    onMute: onMute,
                    onPause: onPause
                )
            }

            // Separates the live controls from the menu, so the ⋯ never reads
            // as a third mid-question button.
            ToolbarSpacer(.fixed, placement: .topBarTrailing)

            ToolbarItem(placement: .topBarTrailing) {
                QuizOverflowMenu(
                    onSettings: onSettings,
                    onFeedback: onFeedback,
                    onRateQuestion: onRateQuestion
                )
            }
        }
    }
}

/// #188 G9: how large Dynamic Type may make the quiz screens (question, answer
/// sheet, result). At the largest accessibility sizes the MCQ options alone
/// covered the screen (founder audit D7–D11). The founder found `.xxxLarge` too
/// small (review 2026-10-07), so the cap is `.accessibility2`: the highest size
/// at which the question stays visible, the options scroll behind their cue and
/// no control text is cut. Screens outside the quiz are not capped.
enum QuizTypeSize {
    static let screenCap: DynamicTypeSize = .accessibility2
    /// The question is display type (26–30 pt Anton) that already reads larger
    /// than body text; one step under the screen cap keeps the stem above the
    /// options instead of under the scroll cue (D11).
    static let questionCap: DynamicTypeSize = .accessibility1
}

/// #179 D2 (founder 2026-09-15, variant A): the two mid-question controls are
/// ONE visibly joined pill with a divider between them. They were already a
/// `ToolbarItemGroup`, but the system spacing pushed them apart until they read
/// as two unrelated buttons — the founder's 2026-09-14 report. ⋯ deliberately
/// stays OUTSIDE the pill: a third target in the same shape invites a menu tap
/// meant for pause, which is the last thing a driver needs mid-question.
///
/// #181 (founder, TF build 62): the pill draws NO background or border of its
/// own. It is one `ToolbarItem`, so the system already wraps it in the same
/// glass capsule ✕ and ⋯ get — a card fill plus hairline on top of that made it
/// the one control in the bar that looked hand-drawn. Only the divider is ours.
struct QuizControlPill: View {
    let isMuted: Bool
    let isPaused: Bool
    /// Pause is dead in the states that cannot be frozen — but a PAUSED quiz
    /// always keeps its way back (#173 decision 4).
    let isPauseEnabled: Bool
    let onMute: () -> Void
    let onPause: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            QuizMuteToolbarButton(isMuted: isMuted, action: onMute)
                .frame(width: 42, height: 30)

            Rectangle()
                .fill(Theme.Hangs.Colors.hairline)
                .frame(width: 1, height: 18)
                .accessibilityHidden(true)

            QuizPauseToolbarButton(isPaused: isPaused, action: onPause)
                .frame(width: 42, height: 30)
                .disabled(!isPauseEnabled)
        }
        // Deliberately NO identifier on the pill: `accessibilityIdentifier` is
        // inherited, so one here overwrites `question.mute` / `question.pause`
        // on the children and both controls vanish from the UI-test tree
        // (caught by the #179 screenshot pass). The pill is chrome; the two
        // buttons inside it are what anything automated or assistive addresses.
    }
}

/// Mute toggle — pink while muted so a silenced quiz is visible at a glance
/// (the #173 finding 1a root cause: a mute carried over from a previous run).
///
/// #179 D2 icon rule "outline = off, fill = on": sound on is the outline
/// `speaker.wave.2`; muted is filled AND pink, because a silenced quiz is a
/// state the driver has to notice in peripheral vision.
struct QuizMuteToolbarButton: View {
    let isMuted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2")
        }
        .tint(isMuted ? Theme.Hangs.Colors.action : Theme.Hangs.Colors.ink)
        .accessibilityLabel(isMuted ? Text("Unmute") : Text("Mute"))
        .accessibilityIdentifier("question.mute")
    }
}

/// Quiz-level pause — available in EVERY state now (#173 founder decision 4),
/// not just on the answer confirmation sheet it used to be trapped on.
///
/// #179 D2 icon rule: a running quiz is NOT a paused one, so pause is the
/// outline `pause`; once paused, `play.fill` — the one active state in the bar,
/// and the founder kept it blue as the single "carry on" cue.
struct QuizPauseToolbarButton: View {
    let isPaused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPaused ? "play.fill" : "pause")
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
                    ToolbarItem(placement: .topBarTrailing) {
                        QuizControlPill(
                            isMuted: true,
                            isPaused: false,
                            isPauseEnabled: true,
                            onMute: {},
                            onPause: {}
                        )
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        QuizOverflowMenu(onSettings: {}, onFeedback: {}, onRateQuestion: {})
                    }
                }
        }
    }
#endif
