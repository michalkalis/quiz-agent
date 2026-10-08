//
//  AppNoticeBanner.swift
//  Hangs
//
//  Short server-supplied notice on Home (#193 task 193.9), e.g. planned
//  maintenance. Dismissible; the same text stays dismissed across launches,
//  a new text shows again. Renders nothing when there is no notice.
//

import SwiftUI

struct AppNoticeBanner: View {
    private enum Metrics {
        static let iconSize: CGFloat = 15
        static let tapTarget: CGFloat = 44
    }

    @ObservedObject var store: AppConfigStore

    var body: some View {
        if let notice = store.notice {
            HangsCard(padding: EdgeInsets(
                top: Theme.Hangs.Spacing.xxs,
                leading: Theme.Hangs.Spacing.md,
                bottom: Theme.Hangs.Spacing.xxs,
                trailing: Theme.Hangs.Spacing.xxs
            )) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    Image(systemName: "info.circle")
                        .font(.system(size: Metrics.iconSize, weight: .semibold))
                        .foregroundStyle(Theme.Hangs.Colors.accentPrimary)
                        .accessibilityHidden(true)
                    Text(verbatim: notice)
                        .font(.hangsBody)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Theme.Hangs.Spacing.sm)
                        .accessibilityIdentifier("home.notice.text")
                    Button(action: store.dismissNotice) {
                        Image(systemName: "xmark")
                            .font(.system(size: Metrics.iconSize, weight: .semibold))
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Dismiss", comment: "Accessibility label: hide the notice on Home"))
                    .accessibilityIdentifier("home.notice.dismiss")
                }
            }
        }
    }
}
