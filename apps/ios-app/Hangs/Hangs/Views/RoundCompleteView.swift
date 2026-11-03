//
//  RoundCompleteView.swift
//  Hangs
//
//  #194 C5 (founder round 4, R-Complete): the end of a round is ONE screen —
//  the score and the answer list together. It used to be two (`CompletionView`
//  after per-question reveal, `SetRecapView` after an end-of-set reveal); both
//  routes stay (the view model still picks one), and both now draw this.
//
//  #224 (founder, TF 2026-11-02, canvas B4a): calmer. The score is one big
//  figure ("7 of 10") with a one-line breakdown, the round a single-colour row
//  of cells, the list plain rows: green stays on the right answers only.
//
//  Critical spots kept: the hero is one line with no sentence under it, the
//  breakdown counts the whole round, the list groups each answer under its
//  question and a row expands to the full question + source. The voice
//  commands that work here ("znova", "domov") are named in the listen bar.
//

import SwiftUI

struct RoundCompleteView: View {
    /// Which route landed here. It decides the identifiers (the RS suite and
    /// the inspector tests address each route by its own) and whether the
    /// spoken summary control is offered.
    enum Route {
        /// Per-question reveal: the driver has already heard every verdict.
        case score
        /// End-of-set reveal: the answers are new here, and narrated.
        case recap

        var idPrefix: String { self == .score ? "completion" : "recap" }
    }

    @ObservedObject var viewModel: QuizViewModel
    @Environment(\.locale) private var locale
    let route: Route
    let summary: QuizCompleteSummary
    /// Free questions left when the upsell applies (score route only).
    var upsellRemaining: Int?

    @State private var expandedEntryId: Int?
    @State private var sourceSheet: RecapSource?

    private enum Metrics {
        /// Canvas B4a: the score figure (64 display).
        static let figure: CGFloat = 64
        /// R-Complete: Home beside the main action.
        static let homeWidth: CGFloat = 124
    }

    var body: some View {
        VStack(spacing: 0) {
            // #198: the logo stays on Home and Onboarding only.
            HangsTopBar {
                HangsNavChip(icon: "xmark", label: "Close") { viewModel.resetToHome() }
                    .accessibilityIdentifier("\(route.idPrefix).close")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                    scoreBlock

                    if !viewModel.recapEntries.isEmpty {
                        RoundCardRow(outcomes: cardOutcomes)
                            .padding(.top, Theme.Hangs.Spacing.xs)
                            .accessibilityIdentifier("\(route.idPrefix).cards")
                    }

                    if let upsellRemaining {
                        upsellCard(remaining: upsellRemaining)
                    }

                    if !viewModel.recapEntries.isEmpty {
                        listHeader
                            .padding(.top, Theme.Hangs.Spacing.xs)
                        answerList
                    }
                }
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.bottom, Theme.Hangs.Spacing.sm)
            }

            footer
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .sheet(item: $sourceSheet) { source in
            SourceWebView(
                url: source.id,
                isPresented: Binding(
                    get: { sourceSheet != nil },
                    set: { if !$0 { sourceSheet = nil } }
                )
            )
        }
    }

    // MARK: - Score

    /// Canvas B4a: the category as a quiet label, the score as one big figure
    /// with "out of N" beside it, and the breakdown as a single line.
    private var scoreBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            if let categoryName {
                Text(verbatim: categoryName)
                    .textCase(.uppercase)
                    .font(.hangsOverline)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Hangs.Colors.sectionLabel)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Hangs.Spacing.xs) {
                Text(verbatim: summary.displayScore)
                    .font(.hangsDisplay(Metrics.figure))
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("out of \(summary.totalQuestions)")
                    .font(.hangsSubHero)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Final score: \(summary.displayScore) out of \(summary.totalQuestions)", bundle: .interface, locale: .interface, comment: "Accessibility label for the final-score card"))
            .accessibilityIdentifier(route == .score ? "completion.score" : "recap.hero")

            Text("Correct \(correctCount) · Missed \(incorrectCount) · Skipped \(skippedCount)")
                .font(.hangsBody)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("completion.breakdown")
        }
    }

    private var correctCount: Int { viewModel.recapEntries.count(where: \.isCorrect) }
    private var skippedCount: Int { viewModel.recapEntries.count(where: \.wasSkipped) }
    /// Every question that is neither right nor skipped, a partly right answer
    /// included: the beta's recap counted it the same way.
    private var incorrectCount: Int { viewModel.recapEntries.count - correctCount - skippedCount }

    // MARK: - Upsell (score route, free plan running low)

    private func upsellCard(remaining: Int) -> some View {
        Button {
            viewModel.presentPaywall(source: .completion)
        } label: {
            HangsCard(padding: EdgeInsets(
                top: Theme.Hangs.Spacing.sm, leading: Theme.Hangs.Spacing.md,
                bottom: Theme.Hangs.Spacing.sm, trailing: Theme.Hangs.Spacing.md
            )) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                        Text("Running low on free questions")
                            .font(.hangsLabel)
                            .foregroundStyle(Theme.Hangs.Colors.ink)
                        Text("^[\(remaining) free questions](inflect: true) left this month.")
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                    }
                    Spacer(minLength: Theme.Hangs.Spacing.xs)
                    Text("Get Trubbo Plus")
                        .font(.hangsCaption.weight(.semibold))
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .padding(.horizontal, Theme.Hangs.Spacing.sm)
                        .padding(.vertical, Theme.Hangs.Spacing.xs)
                        .background(Capsule().fill(Theme.Hangs.Colors.bgInset))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("completion.upsell")
    }

    // MARK: - Answer list

    private var listHeader: some View {
        HStack(alignment: .center, spacing: Theme.Hangs.Spacing.xs) {
            HangsSectionLabel(text: "Questions")
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            if route == .recap {
                summaryControl
            }
        }
    }

    private var cardOutcomes: [RoundCardRow.Outcome] {
        viewModel.recapEntries.map { entry in
            if entry.wasSkipped { return .skipped }
            return entry.isCorrect ? .correct : .incorrect
        }
    }

    /// #198: nil for a category outside the taxonomy — the label then names no category.
    private var categoryName: String? {
        viewModel.recapEntries.first.flatMap { Config.categoryDisplayName(for: $0.category, locale: locale) }
    }

    /// End-of-set route: the spoken summary (it starts by itself hands-free).
    private var summaryControl: some View {
        Button {
            viewModel.toggleRecapNarration()
        } label: {
            Label(summaryTitle, systemImage: viewModel.isNarratingRecap ? "stop.fill" : "speaker.wave.2")
            .font(.hangsCaption.weight(.semibold))
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .padding(.horizontal, Theme.Hangs.Spacing.sm)
            .frame(minHeight: Theme.Hangs.Spacing.xxl)
            .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isAudioMuted)
        .opacity(viewModel.isAudioMuted ? 0.45 : 1)
        .accessibilityIdentifier("recap.playSummary")
    }

    private var summaryTitle: LocalizedStringKey {
        viewModel.isNarratingRecap ? "Stop summary" : "Play summary"
    }

    private var answerList: some View {
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
                    onToggle: { toggle(entry.id) },
                    onHearIt: { viewModel.playRecapEntryExplanation(entry) },
                    onOpenSource: { sourceSheet = RecapSource(id: $0) }
                )
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous))
        .hangsShadow(Theme.Hangs.Shadow.card)
    }

    private func toggle(_ id: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedEntryId = expandedEntryId == id ? nil : id
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            // Founder round 4: the commands are shown wherever they work —
            // here "znova" plays again and "domov" goes Home.
            if viewModel.commandListenerHint != nil {
                ListenBar(
                    mode: .command,
                    feedback: viewModel.voiceFeedbackPhase,
                    recognizingWord: viewModel.recognizingWord,
                    commandHint: viewModel.voiceHintWords,
                    language: viewModel.commandLanguage
                )
                .transition(.opacity)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Hangs.Spacing.sm) {
                    playAgainButton
                    homeButton.frame(width: Metrics.homeWidth)
                }
                VStack(spacing: Theme.Hangs.Spacing.xs) {
                    playAgainButton
                    homeButton
                }
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    private var playAgainButton: some View {
        HangsPrimaryButton(title: "Play Again", icon: "arrow.counterclockwise") {
            viewModel.playAgain()
        }
        .accessibilityIdentifier("\(route.idPrefix).playAgain")
    }

    private var homeButton: some View {
        HangsSecondaryButton(title: "Home", icon: "house.fill") {
            viewModel.resetToHome()
        }
        .accessibilityIdentifier("\(route.idPrefix).home")
    }
}
