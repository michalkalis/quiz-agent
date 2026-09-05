//
//  HangsProcessingOverlay.swift
//  Hangs
//
//  #171 Track E, variant B1 (founder, 2026-09-05): while an answer is being
//  evaluated the question screen used to swap its bottom controls for a small
//  spinner row — the screen's busiest corner became its emptiest, and the driver
//  read it as "the app fell over". The state now lifts above the whole screen:
//  the question stays visible but dimmed and blurred behind a centred card, and
//  the bottom of the screen is deliberately empty (B1 beat B2, full-screen,
//  because losing the question loses the context you are waiting on).
//
//  Same overlay for voice and MCQ — there is one evaluating state, not two.
//

import SwiftUI

struct HangsProcessingOverlay: View {
    /// The answer that was just submitted, echoed back so the driver can see the
    /// app heard them right. Empty = no answer to show (a skip, or a path that
    /// never produced a transcript) and the line is dropped.
    var submittedAnswer: String = ""

    var body: some View {
        ZStack {
            // The question stays legible-but-receded underneath: the material
            // blurs it, the tint dims it. Deliberately lighter than the mock's
            // flat 86% wash — a backdrop blur in SwiftUI already darkens what it
            // blurs, and stacking both hides the question B1 exists to keep.
            Rectangle()
                .fill(Theme.Hangs.Colors.bg.opacity(0.60))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.Hangs.Colors.pink)

                Text("Evaluating…")
                    .font(.hangsDisplay(34))
                    .textCase(.uppercase)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if !submittedAnswer.isEmpty {
                    Text("You said: “\(submittedAnswer)”")
                        .font(.hangsBody(15))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 30)
            .frame(minWidth: 250)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
            )
            .hangsShadow(Theme.Hangs.Shadow.card)
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("question.processingIndicator")
    }
}

#if DEBUG
    #Preview {
        ZStack {
            Theme.Hangs.Colors.bg.ignoresSafeArea()
            Text(verbatim: "the question underneath")
                .font(.hangsDisplay(28))
            HangsProcessingOverlay(submittedAnswer: "the bell")
        }
    }
#endif
