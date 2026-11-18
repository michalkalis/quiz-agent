//
//  HomeSharedQuizPasteRow.swift
//  Hangs
//
//  #232 (founder 2026-11-14, quieter than 3A and 3B): ONE row on Home on the
//  first launch after install, only while the clipboard probably holds a
//  link: "Got a quiz link from a friend?" with Apple's Paste button, which
//  reads the clipboard without the paste alert. Gone after ✕ or the first
//  quiz, so most players never see it.
//

import SwiftUI
import UniformTypeIdentifiers

struct HomeSharedQuizPasteRow: View {
    private enum Metrics {
        static let iconSize: CGFloat = 15
        static let tapTarget: CGFloat = 44
    }

    @ObservedObject var inbox: SharedQuizInbox
    @ObservedObject var appConfig: AppConfigStore

    var body: some View {
        if appConfig.sharedQuizEnabled, inbox.offersPaste {
            row
        }
    }

    private var row: some View {
        HangsCard(padding: EdgeInsets(
            top: Theme.Hangs.Spacing.xs,
            leading: Theme.Hangs.Spacing.md,
            bottom: Theme.Hangs.Spacing.xs,
            trailing: Theme.Hangs.Spacing.xxs
        )) {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    Text("Got a quiz link from a friend?")
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    PasteButton(supportedContentTypes: [.url, .plainText]) { providers in
                        Task { await inbox.paste(providers: providers) }
                    }
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("home.sharedQuiz.paste")
                    Button(action: inbox.dismissPasteOffer) {
                        Image(systemName: "xmark")
                            .font(.hangsBody(Metrics.iconSize, weight: .semibold))
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Close"))
                    .accessibilityIdentifier("home.sharedQuiz.dismiss")
                }
                if inbox.pasteMissed {
                    Text("That's not a quiz link. Tap the link in the message again.")
                        .font(.hangsCaption)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.trailing, Theme.Hangs.Spacing.sm)
                        .accessibilityIdentifier("home.sharedQuiz.notALink")
                }
            }
        }
    }
}
