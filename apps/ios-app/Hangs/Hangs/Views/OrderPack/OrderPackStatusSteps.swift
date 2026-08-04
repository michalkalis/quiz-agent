//
//  OrderPackStatusSteps.swift
//  Hangs
//
//  Post-purchase states of the #138 order sheet: Preparing, Ready, Failed.
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
        VStack(spacing: 20) {
            HangsCard(padding: EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)) {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Theme.Hangs.Colors.pink)
                    Text("Building your pack…")
                        .font(.hangsBody(17, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                        .multilineTextAlignment(.center)
                    Text("Usually takes a few minutes. The first order after a longer break can take a bit extra.")
                        .font(.hangsBody(13))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can close the app — your finished pack will be waiting in My packs.")
                        .font(.hangsBody(13))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let progress {
                        ProgressView(value: progress)
                            .tint(Theme.Hangs.Colors.blue)
                    }
                }
                .frame(maxWidth: .infinity)
            }

            HangsPrimaryButton(title: "Got it", action: onDismiss)
                .accessibilityIdentifier("orderPack.gotIt")
        }
    }
}

/// `.delivered` — the pack exists; play it now or find it in My packs later.
struct OrderPackReadyStep: View {
    let packId: String?
    let onPlayPack: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HangsCard(padding: EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)) {
                VStack(spacing: 12) {
                    HangsResultBanner(kind: .correct)
                    Text("Your pack is ready")
                        .font(.hangsBody(18, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                }
                .frame(maxWidth: .infinity)
            }

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

/// `.failed` — including the soft "still working" timeout. "Try again" re-runs
/// the order that was already paid for (backend retry), never a second charge.
struct OrderPackFailedStep: View {
    let message: String
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            HangsCard(padding: EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.error)
                    Text(verbatim: message)
                        .font(.hangsBody(16))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            HangsPrimaryButton(title: "Try again", icon: "arrow.clockwise", action: onRetry)
                .accessibilityIdentifier("orderPack.retry")

            HangsSecondaryButton(title: "Close", action: onClose)
                .accessibilityIdentifier("orderPack.closeButton")
        }
    }
}

#if DEBUG
    #Preview {
        ScrollView {
            VStack(spacing: 24) {
                OrderPackPreparingStep(progress: 0.4, onDismiss: {})
                OrderPackReadyStep(packId: "pack", onPlayPack: { _ in }, onClose: {})
                OrderPackFailedStep(message: "Pack generation failed.", onRetry: {}, onClose: {})
            }
            .padding(20)
        }
        .background(Theme.Hangs.Colors.bg)
    }
#endif
