//
//  SetRecapView.swift
//  Hangs
//
//  #132 Track E — end-of-set recap, founder pick 2026-07-29: variant C
//  "Zoznam s rozbalením". Score hero on top, every question of the set as an
//  expandable row (tap → your answer + explanation + hear-it), skipped
//  questions as neutral rows. Replaces CompletionView at `.finished` ONLY when
//  the reveal mode is `.endOfSet` — the per-question flow keeps today's
//  CompletionView untouched.
//
//  Deliberately NO ListenBar here: the command window never arms on
//  `.finished` (VoiceCommandCoordinator maps it to nil), and a bar claiming
//  "LISTENING" over a dead mic is exactly the lie #132 A removed. The mock
//  sketched one; the shipped behavior wins. Narration is the hands-free
//  affordance instead: auto-read on appear (autoRecordEnabled) + the CTA.
//

import SwiftUI

struct SetRecapView: View {
    @ObservedObject var viewModel: QuizViewModel
    @State private var expandedEntryId: Int?
    /// #179: the source a row asked to open. ONE sheet for the whole list —
    /// the rows just report the URL, they own no presentation state.
    @State private var sourceSheet: RecapSource?

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow {
                HangsNavChip(icon: "xmark", label: "Close") { viewModel.resetToHome() }
                    .accessibilityIdentifier("recap.close")
            }

            ScrollView {
                VStack(spacing: 0) {
                    hero
                        .padding(.horizontal, Theme.Hangs.Spacing.lg)
                        .padding(.top, Theme.Hangs.Spacing.xs)

                    rowsList
                        .padding(.horizontal, Theme.Hangs.Spacing.lg)
                        .padding(.top, Theme.Hangs.Spacing.md)
                }
                .padding(.bottom, Theme.Hangs.Spacing.sm)
            }

            ctaStack
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        // #179: the SAME in-app reader the result screen opens — a driver must
        // never be thrown out to Safari mid-recap.
        .sheet(item: $sourceSheet) { source in
            SourceWebView(
                url: source.id,
                isPresented: Binding(
                    get: { sourceSheet != nil },
                    set: { if !$0 { sourceSheet = nil } }
                )
            )
        }
        .onAppear { viewModel.autoPlayRecapIfHandsFree() }
        .onDisappear { viewModel.stopRecapNarration() }
        .task { await viewModel.refreshUsage() }
    }

    // MARK: - Score hero

    private var correctCount: Int { viewModel.recapEntries.filter(\.isCorrect).count }
    private var skippedCount: Int { viewModel.recapEntries.filter(\.wasSkipped).count }
    private var missedCount: Int { viewModel.recapEntries.count - correctCount - skippedCount }

    private var hero: some View {
        VStack(spacing: 10) {
            Text("SET RESULT · \(viewModel.recapEntries.first.map { Config.categoryDisplayName(for: $0.category) } ?? "")")
                .textCase(.uppercase)
                .font(.hangsMono(11, weight: .medium))
                .tracking(2)
                .foregroundColor(Theme.Hangs.Colors.mutedFaint)

            Text(verbatim: "\(correctCount)/\(viewModel.recapEntries.count)")
                .font(.hangsNumberLG)
                .tracking(-3)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            HStack(spacing: Theme.Hangs.Spacing.xs) {
                chip(glyph: "✓", Text("\(correctCount) CORRECT"),
                     color: correctCount > 0 ? Theme.Hangs.Colors.successText : Theme.Hangs.Colors.muted,
                     fill: correctCount > 0 ? Theme.Hangs.Colors.greenSoft : Theme.Hangs.Colors.neutralSoft)
                // A zero is no news either way: neutral, not a red "0 missed" (#188 G14).
                chip(glyph: "✗", Text("\(missedCount) MISSED"),
                     color: missedCount > 0 ? Theme.Hangs.Colors.pinkText : Theme.Hangs.Colors.muted,
                     fill: missedCount > 0 ? Theme.Hangs.Colors.pinkSoft : Theme.Hangs.Colors.neutralSoft)
                chip(glyph: "–", Text("\(skippedCount) SKIPPED"),
                     color: Theme.Hangs.Colors.muted,
                     fill: Theme.Hangs.Colors.neutralSoft)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recap.hero")
    }

    private func chip(glyph: String, _ label: Text, color: Color, fill: Color) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            Text(verbatim: glyph)
            label
        }
        .font(.hangsMono(11, weight: .semibold))
        .tracking(0.5)
        .foregroundColor(color)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(fill))
    }

    // MARK: - Rows

    /// #189 finding 3: one grouped card for the whole set instead of a stack of
    /// separate row cards — a hairline divider between rows stands in for the
    /// per-row border, inset so it starts after the badge column (not under it).
    private var rowsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(viewModel.recapEntries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.Hangs.Colors.hairline)
                        .frame(height: 1)
                        .padding(.leading, SetRecapRow.groupDividerInset)
                }

                SetRecapRow(
                    entry: entry,
                    isExpanded: expandedEntryId == entry.id,
                    hearItDisabled: viewModel.isAudioMuted,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedEntryId = expandedEntryId == entry.id ? nil : entry.id
                        }
                    },
                    onHearIt: { viewModel.playRecapEntryExplanation(entry) },
                    onOpenSource: { sourceSheet = RecapSource(id: $0) }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card)
                .stroke(Theme.Hangs.Colors.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card))
    }

    // MARK: - CTA stack

    private var ctaStack: some View {
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            HangsPrimaryButton(
                title: viewModel.isNarratingRecap ? "Stop summary" : "Play summary",
                icon: viewModel.isNarratingRecap ? "stop.fill" : "speaker.wave.2",
                height: 56
            ) {
                viewModel.toggleRecapNarration()
            }
            .disabled(viewModel.isAudioMuted)
            .accessibilityIdentifier("recap.playSummary")

            HStack(spacing: Theme.Hangs.Spacing.xs) {
                HangsSecondaryButton(
                    title: "Play Again",
                    icon: "arrow.counterclockwise",
                    height: 48
                ) {
                    Task { await viewModel.startNewQuiz() }
                }
                .accessibilityIdentifier("recap.playAgain")

                HangsSecondaryButton(
                    title: "Home",
                    icon: "house.fill",
                    height: 48
                ) {
                    viewModel.resetToHome()
                }
                .accessibilityIdentifier("recap.home")
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.lg)
        .padding(.bottom, 14)
    }
}

// MARK: - Row

/// The source URL a row asked to open — the URL is the identity, so tapping the
/// same row twice re-presents the same sheet rather than a second one.
struct RecapSource: Identifiable, Equatable {
    let id: String
}

/// One recap row inside `SetRecapView`'s grouped list (#189 finding 3).
/// Collapsed: badge + 1-line question teaser + the revealed answer (wraps,
/// never truncated — the answer is visible without expanding) + chevron.
/// Expanded: the full question, the same answer, then "you said" (struck
/// through — it was wrong), explanation, hear-it, source, all inset to the
/// text column so they line up under the question rather than the badge.
struct SetRecapRow: View {
    let entry: RecapEntry
    let isExpanded: Bool
    let hearItDisabled: Bool
    let onToggle: () -> Void
    let onHearIt: () -> Void
    /// Reports the source URL the driver tapped. The row owns no presentation
    /// state — `SetRecapView` holds the one sheet for the whole list. Defaulted
    /// so a test can build a row without caring about the sheet.
    var onOpenSource: (String) -> Void = { _ in }

    /// Badge diameter = the grid's badge column width (#189).
    fileprivate static let badgeSize: CGFloat = 20
    /// Gap between the badge column and the text column.
    fileprivate static let columnGap: CGFloat = 12
    fileprivate static let horizontalPadding: CGFloat = 14
    /// Where the expanded content starts, and — from the group's edge — where
    /// the inter-row hairline in `SetRecapView.rowsList` starts too.
    fileprivate static let textColumnInset = badgeSize + columnGap
    fileprivate static let groupDividerInset = horizontalPadding + textColumnInset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                collapsedRow
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedSection
                    .padding(.leading, Self.textColumnInset)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Theme.Hangs.Spacing.sm)
        .accessibilityIdentifier("recap.row.\(entry.id)")
    }

    private var collapsedRow: some View {
        HStack(alignment: .top, spacing: Self.columnGap) {
            badge

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.questionText)
                    .font(.hangsBody(isExpanded ? 13.5 : 12.5, weight: .medium))
                    .foregroundColor(isExpanded ? Theme.Hangs.Colors.ink : Theme.Hangs.Colors.muted)
                    // #189 finding 3: collapsed is a 1-line teaser (the list is
                    // for glancing, the answer under it carries the row),
                    // expanded owes the driver the whole question.
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)

                Text(entry.correctAnswerDisplay)
                    .font(.hangsBody(15, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.leading)
            }
            // A short question must not pull the chevron off the trailing edge.
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.mutedFaint)
        }
    }

    /// ✓ teal-green / ✗ pink / – neutral dash (a skip is not a failure, #131 D).
    private var badge: some View {
        ZStack {
            Circle().fill(badgeFill)
            Image(systemName: badgeSymbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(badgeColor)
        }
        .frame(width: Self.badgeSize, height: Self.badgeSize)
        .accessibilityHidden(true)
    }

    private var badgeSymbol: String {
        if entry.wasSkipped { return "minus" }
        return entry.isCorrect ? "checkmark" : "xmark"
    }

    private var badgeColor: Color {
        if entry.wasSkipped { return Theme.Hangs.Colors.muted }
        return entry.isCorrect ? Theme.Hangs.Colors.successText : Theme.Hangs.Colors.pinkText
    }

    private var badgeFill: Color {
        if entry.wasSkipped { return Theme.Hangs.Colors.neutralSoft }
        return entry.isCorrect ? Theme.Hangs.Colors.greenSoft : Theme.Hangs.Colors.pinkSoft
    }

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
            Rectangle()
                .fill(Theme.Hangs.Colors.hairline)
                .frame(height: 1)
                .padding(.top, Theme.Hangs.Spacing.sm)
                .padding(.bottom, Theme.Hangs.Spacing.xxs)

            // "you said" only when something wrong was actually said — never on
            // a correct answer (it IS the shown answer) or a skip (#131 D).
            if !entry.isCorrect, let said = entry.userAnswerDisplay {
                HStack(spacing: 6) {
                    Text("you said")
                        .textCase(.uppercase)
                        .font(.hangsMono(10, weight: .semibold))
                        .tracking(1)
                        .foregroundColor(Theme.Hangs.Colors.mutedFaint)
                    Text(said)
                        .strikethrough()
                        .font(.hangsMono(10, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.mutedFaint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityIdentifier("recap.row.\(entry.id).said")
            }

            if let explanation = entry.explanation {
                Text(explanation)
                    .font(.hangsBody(13.5))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onHearIt) {
                    HStack(spacing: 5) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 11, weight: .semibold))
                        Text("hear it")
                            .font(.hangsBody(13, weight: .semibold))
                    }
                    .foregroundColor(Theme.Hangs.Colors.blueText)
                }
                .buttonStyle(.plain)
                .disabled(hearItDisabled)
                .opacity(hearItDisabled ? 0.4 : 1)
                .accessibilityIdentifier("recap.row.\(entry.id).hearIt")
            }

            // #179 finding 8: every revealed answer gets the same source link
            // the result screen offers — same component AND same behaviour, so
            // the two cannot drift. It opens the in-app `SourceWebView` the
            // owner presents; never Safari, which would throw a driver out of
            // the app mid-recap.
            if let sourceUrl = entry.sourceUrl,
               let domain = HangsSourceLink.domain(from: sourceUrl)
            {
                HangsSourceLink(domain: domain) { onOpenSource(sourceUrl) }
                    .accessibilityIdentifier("recap.row.\(entry.id).source")
            }
        }
    }
}
