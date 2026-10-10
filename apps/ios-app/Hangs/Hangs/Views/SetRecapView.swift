//
//  SetRecapView.swift
//  Hangs
//
//  #132 Track E — end-of-set recap (reveal mode `.endOfSet`): every question
//  of the set as an expandable row (tap → your answer + explanation + hear-it).
//
//  #194 C5: the recap and the score screen are ONE end-of-round screen now
//  (`RoundCompleteView`); this route adds the spoken summary, which still
//  starts by itself hands-free. `SetRecapRow` below is that screen's row.
//

import SwiftUI

struct SetRecapView: View {
    @ObservedObject var viewModel: QuizViewModel

    var body: some View {
        // #194 C5: the end-of-set route draws the merged end-of-round screen.
        RoundCompleteView(
            viewModel: viewModel,
            route: .recap,
            summary: QuizCompleteSummary.from(
                score: viewModel.score,
                questionsAnswered: viewModel.questionsAnswered,
                correctCount: viewModel.sessionCorrectCount,
                incorrectCount: viewModel.sessionIncorrectCount,
                maxQuestions: viewModel.currentSession?.maxQuestions
                    ?? viewModel.settings.numberOfQuestions,
                stats: viewModel.quizStats
            )
        )
        .onAppear { viewModel.autoPlayRecapIfHandsFree() }
        .onDisappear { viewModel.stopRecapNarration() }
        .task { await viewModel.refreshUsage() }
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
    fileprivate static let badgeSize: CGFloat = 24
    /// Gap between the badge column and the text column.
    fileprivate static let columnGap: CGFloat = 12
    fileprivate static let horizontalPadding: CGFloat = 16
    /// Where the expanded content starts, and — from the group's edge — where
    /// the inter-row hairline in `SetRecapView.rowsList` starts too.
    fileprivate static let textColumnInset = badgeSize + columnGap
    static let groupDividerInset = horizontalPadding + textColumnInset

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
                    .font(.hangsCaption)
                    .foregroundColor(isExpanded ? Theme.Hangs.Colors.ink : Theme.Hangs.Colors.muted)
                    // #189 finding 3: collapsed is a 1-line teaser (the list is
                    // for glancing, the answer under it carries the row),
                    // expanded owes the driver the whole question.
                    .lineLimit(isExpanded ? nil : 1)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)

                Text(entry.correctAnswerDisplay)
                    // #194: answers are content — Rethink Sans.
                    .font(.hangsContent)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.leading)
            }
            // A short question must not pull the chevron off the trailing edge.
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.hangsCaption.weight(.semibold))
                .foregroundColor(Theme.Hangs.Colors.mutedFaint)
        }
    }

    /// ✓ teal-green / ✗ pink / – neutral dash (a skip is not a failure, #131 D).
    private var badge: some View {
        ZStack {
            Circle().fill(badgeFill)
            Image(systemName: badgeSymbol)
                .font(.hangsCaption.weight(.bold))
                .foregroundColor(badgeColor)
        }
        .frame(width: Self.badgeSize, height: Self.badgeSize)
        .accessibilityHidden(true)
    }

    private var badgeSymbol: String {
        if entry.wasSkipped { return "minus" }
        return entry.isCorrect ? "checkmark" : "xmark"
    }

    /// #194 R-Complete: a solid green plate for a right answer; a wrong one
    /// stays neutral (B1), a skip is the quietest.
    private var badgeColor: Color {
        if entry.wasSkipped { return Theme.Hangs.Colors.muted }
        return entry.isCorrect ? Theme.Hangs.Colors.textOnAccent : Theme.Hangs.Colors.wrong
    }

    private var badgeFill: Color {
        if entry.wasSkipped { return Theme.Hangs.Colors.track }
        return entry.isCorrect ? Theme.Hangs.Colors.greenCheck : Theme.Hangs.Colors.neutralSoft
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
                    HangsSectionLabel(text: "you said")
                    Text(said)
                        .strikethrough()
                        .font(.hangsContent)
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityIdentifier("recap.row.\(entry.id).said")
            }

            if let explanation = entry.explanation {
                Text(explanation)
                    .font(.hangsBodyLG)
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onHearIt) {
                    // R-Complete: a page-grey chip, like the result card's.
                    Label {
                        Text("hear it")
                    } icon: {
                        Image(systemName: "speaker.wave.2")
                    }
                    .font(.hangsCaption.weight(.semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .padding(.horizontal, Theme.Hangs.Spacing.sm)
                    .frame(minHeight: Theme.Hangs.Spacing.xxl)
                    .background(Capsule().fill(Theme.Hangs.Colors.bgInset))
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
