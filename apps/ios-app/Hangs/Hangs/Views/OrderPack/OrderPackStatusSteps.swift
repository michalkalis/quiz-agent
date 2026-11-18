//
//  OrderPackStatusSteps.swift
//  Hangs
//
//  Post-purchase states of the #138 order sheet: Preparing, Still preparing,
//  Ready, Failed.
//  None of them offers a route back to the form — the order is paid for.
//  "Close"/"Got it"/X dismiss the sheet WITHOUT cancelling: generation keeps
//  running and the pack lands in My packs either way, which is exactly what the
//  copy promises.
//

import SwiftUI

/// `.submitting` / `.polling` — the wait, with an honest ETA and permission to
/// leave. The founder's field test stalled here with no idea whether minutes or
/// hours were expected, and no way out but the back button.
struct OrderPackPreparingStep: View {
    /// Job progress 0…1 when the backend reports one; nil while submitting.
    let progress: Double?
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.lg) {
            // #194 C8: the pack being dealt — the deck, a spinner on it.
            ZStack {
                PackMiniDeck(label: "", style: Theme.Hangs.Category.style(forPack: nil), size: .hero)
                ProgressView()
                    .tint(Theme.Hangs.Category.style(forPack: nil).text)
            }
            .padding(.top, Theme.Hangs.Spacing.lg)

            VStack(spacing: Theme.Hangs.Spacing.sm) {
                Text("Building your pack…")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("We check every question against sources, so it takes a few minutes.")
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can close the app — your finished pack will be waiting in My packs.")
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: progress)
                        .tint(Theme.Hangs.Colors.accentPrimary)
                        .padding(.top, Theme.Hangs.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity)

            HangsPrimaryButton(title: "Got it", action: onDismiss)
                .accessibilityIdentifier("orderPack.gotIt")
        }
    }
}

/// `.stillPreparing` — the foreground wait ran out but the pack is still being
/// made (#240, 240.9). It must not read as a failure: it says the pack is on
/// its way and where it will appear, and closing is the whole action.
struct OrderPackStillPreparingStep: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.lg) {
            PackMiniDeck(label: "", style: Theme.Hangs.Category.style(forPack: nil), size: .hero)
                .overlay {
                    Image(systemName: "clock")
                        .font(.hangsTitle)
                        .foregroundStyle(Theme.Hangs.Category.style(forPack: nil).text)
                        .accessibilityHidden(true)
                }
                .padding(.top, Theme.Hangs.Spacing.lg)

            VStack(spacing: Theme.Hangs.Spacing.sm) {
                Text("Still preparing your pack")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("It is taking longer than usual. When it's ready, you'll find it in My packs.")
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("orderPack.stillPreparing")

            HangsPrimaryButton(title: "Got it", action: onClose)
                .accessibilityIdentifier("orderPack.gotIt")
        }
    }
}

/// `.delivered` — the pack exists; play it now or find it in My packs later.
/// Since #182 it is also the screen for a pack that is playable but still
/// growing: the first batch is enough to start, and the rest is written while
/// the player plays.
struct OrderPackReadyStep: View {
    let packId: String?
    /// #182: the worker is still adding questions to this pack.
    var isStillGenerating: Bool = false
    /// Questions playable right now / questions ordered (#182 copy).
    var readyCount: Int = 0
    var targetCount: Int = 0
    let onPlayPack: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.lg) {
            // #194 C8 (canvas Bg-PackGenerating): the dealt deck with the
            // playable count, a check, the headline, one segment per question.
            PackMiniDeck(
                label: "\(isStillGenerating ? readyCount : targetCount)",
                style: Theme.Hangs.Category.style(forPack: packId),
                size: .hero
            )
            .padding(.top, Theme.Hangs.Spacing.lg)

            VStack(spacing: Theme.Hangs.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.live)
                    .accessibilityHidden(true)
                Text(isStillGenerating ? "Your pack is ready to play" : "Your pack is ready")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                if isStillGenerating {
                    Text("\(readyCount) of \(targetCount) questions ready. The rest keeps generating while you play.")
                        .font(.hangsBodyLG)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("orderPack.readyCount")
                    PackReadySegments(ready: readyCount, total: targetCount)
                        .padding(.top, Theme.Hangs.Spacing.xs)
                }
            }
            .frame(maxWidth: .infinity)

            if let packId {
                HangsPrimaryButton(title: "Start quiz", icon: "play.fill") {
                    onPlayPack(packId)
                }
                .accessibilityIdentifier("orderProgress.startQuiz")
            }

            HangsSecondaryButton(title: "Close", action: onClose)
                .accessibilityIdentifier("orderPack.closeButton")
        }
    }
}

/// `.failed`. A retryable failure offers "Try again", which re-runs the order
/// that was already paid for (backend retry), never a second charge.
///
/// A refunded order or a spent retry budget is NOT retryable: the retry
/// endpoint would refuse and dump raw backend text on the user (review
/// finding 2). There the only honest action is to close. (A poll that ran out
/// of time is no failure at all: `OrderPackStillPreparingStep`.)
struct OrderPackFailedStep: View {
    let message: String
    var isRetryable: Bool = true
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.lg) {
            HangsCard(padding: EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)) {
                VStack(spacing: Theme.Hangs.Spacing.sm) {
                    Image(systemName: isRetryable ? "exclamationmark.triangle" : "clock.badge.checkmark")
                        .font(.hangsTitle)
                        .foregroundStyle(isRetryable ? Theme.Hangs.Colors.error : Theme.Hangs.Colors.blueText)
                    Text(verbatim: message)
                        .font(.hangsBodyLG)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            if isRetryable {
                HangsPrimaryButton(title: "Try again", icon: "arrow.clockwise", action: onRetry)
                    .accessibilityIdentifier("orderPack.retry")

                HangsSecondaryButton(title: "Close", action: onClose)
                    .accessibilityIdentifier("orderPack.closeButton")
            } else {
                // Nothing to retry — the order is alive server-side. Closing is
                // the whole action, so it takes the primary slot.
                HangsPrimaryButton(title: "Got it", action: onClose)
                    .accessibilityIdentifier("orderPack.gotIt")
            }
        }
    }
}

#if DEBUG
    #Preview {
        ScrollView {
            VStack(spacing: 24) {
                OrderPackPreparingStep(progress: 0.4, onDismiss: {})
                OrderPackReadyStep(packId: "pack", onPlayPack: { _ in }, onClose: {})
                OrderPackReadyStep(
                    packId: "pack",
                    isStillGenerating: true,
                    readyCount: 5,
                    targetCount: 30,
                    onPlayPack: { _ in },
                    onClose: {}
                )
                OrderPackFailedStep(message: "Pack generation failed.", onRetry: {}, onClose: {})
                OrderPackStillPreparingStep(onClose: {})
            }
            .padding(20)
        }
        .background(Theme.Hangs.Colors.bg)
    }
#endif
