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
//  commands that work here ("ďalší", "domov") are named in the listen bar.
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

    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var viewModel: QuizViewModel
    /// #232: this round's link and comparison (sender or friend).
    @StateObject private var share: SharedQuizShareModel
    let route: Route
    let summary: QuizCompleteSummary
    /// Free questions left when the upsell applies (score route only).
    var upsellRemaining: Int?

    init(viewModel: QuizViewModel, route: Route, summary: QuizCompleteSummary, upsellRemaining: Int? = nil) {
        self.viewModel = viewModel
        self.route = route
        self.summary = summary
        self.upsellRemaining = upsellRemaining
        _share = StateObject(wrappedValue: SharedQuizShareModel(
            network: viewModel.networkService,
            source: viewModel.shareableRoundSessionId.map { .session($0) },
            token: viewModel.activeShare?.token,
            previewTopic: Self.previewTopic
        ))
    }

    private enum Metrics {
        /// Canvas B4a: the score figure (64 display).
        static let figure: CGFloat = 64
    }

    var body: some View {
        VStack(spacing: 0) {
            // #198: the logo stays on Home and Onboarding only.
            HangsTopBar {
                HStack {
                    HangsNavChip(icon: "xmark", label: "Close") { viewModel.resetToHome() }
                        .accessibilityIdentifier("\(route.idPrefix).close")
                    Spacer()
                    if offersShareIcon {
                        shareIcon
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                    scoreBlock

                    if let highlight = viewModel.roundHighlight {
                        highlightLine(highlight)
                            .padding(.top, Theme.Hangs.Spacing.xxs)
                    }

                    if !viewModel.recapEntries.isEmpty {
                        RoundCardRow(outcomes: cardOutcomes)
                            .padding(.top, Theme.Hangs.Spacing.xs)
                            .accessibilityIdentifier("\(route.idPrefix).cards")
                    }

                    // #232 (1A): sending the round on is the trailing top-bar
                    // icon (#248.3); then (4A) how everyone who played it did.
                    if let failure = share.failureMessage {
                        Text(verbatim: failure)
                            .font(.hangsBody)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("\(route.idPrefix).shareFailed")
                    }
                    if showsSharing, !share.rows.isEmpty {
                        SharedQuizRankingCard(rows: share.rows)
                            .padding(.top, Theme.Hangs.Spacing.xs)
                    }

                    if let upsellRemaining {
                        upsellCard(remaining: upsellRemaining)
                    }

                    if !viewModel.recapEntries.isEmpty {
                        listHeader
                            .padding(.top, Theme.Hangs.Spacing.xs)
                        RecapAnswerList(viewModel: viewModel)
                    }
                }
                .padding(.horizontal, Theme.Hangs.Spacing.md)
                .padding(.bottom, Theme.Hangs.Spacing.sm)
            }

            footer
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .task {
            if showsSharing { share.loadResults() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, showsSharing { share.loadResults() }
        }
    }

    // MARK: - Shared quiz (#232)

    /// The round came from a friend's link (switch on).
    private var isFriendsRound: Bool {
        viewModel.activeShare != nil && viewModel.sharedQuizEnabled()
    }

    /// The comparison has a link to read: the friend's, or the sender's once sent.
    private var showsSharing: Bool {
        viewModel.sharedQuizEnabled() && (isFriendsRound || viewModel.shareableRoundSessionId != nil)
    }

    /// #248.3: Share lives in the top bar, where Apple puts it. A friend's
    /// round has "Send to a friend" as its main button instead.
    private var offersShareIcon: Bool {
        viewModel.shareableRoundSessionId != nil && !isFriendsRound
    }

    private var shareIcon: some View {
        Button(action: sendToFriend) {
            HangsNavChipLabel(icon: "square.and.arrow.up", isLoading: share.isCreating)
        }
        .buttonStyle(.plain)
        .disabled(share.isCreating)
        .accessibilityLabel(Text("Send to a friend"))
        .accessibilityIdentifier("\(route.idPrefix).sendToFriend")
    }

    private func sendToFriend() {
        let score = summary.displayScore
        share.send { SharedQuizMessage.round(questionCount: $0.questionCount, score: score) }
    }

    /// The share sheet's title: the pack's name, else the round's one category.
    private static func previewTopic(_ created: SharedQuizCreated) -> String? {
        if let title = created.title { return title }
        guard created.categories.count == 1, let category = created.categories.first else { return nil }
        return Config.categoryDisplayName(for: category, locale: .interface)
    }

    // MARK: - Highlight (#240.9)

    /// One line worth remembering, above the list: the best run, else the
    /// hardest question answered right.
    private func highlightLine(_ highlight: RoundHighlight) -> some View {
        highlightText(highlight)
            .font(.hangsBody.weight(.semibold))
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("\(route.idPrefix).highlight")
    }

    private func highlightText(_ highlight: RoundHighlight) -> Text {
        switch highlight {
        case let .bestRun(run):
            Text("Best run: \(run) in a row", comment: "End of round, the line it opens with: the longest run of right answers this round")
        case let .hardestRight(answer):
            Text("Hardest one you got: \(answer)", comment: "End of round, the line it opens with: the answer to the hardest question the player got right")
        case .noneRight:
            Text("None right this time. All the answers are below.", comment: "End of round, the line it opens with when no answer was right")
        }
    }

    // MARK: - Score

    /// Canvas B4a: the category as a quiet label, the score as one big figure
    /// with "out of N" beside it, and the breakdown as a single line.
    private var scoreBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
            if isFriendsRound {
                friendsQuizLabel
                    .textCase(.uppercase)
                    .font(.hangsOverline)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Hangs.Colors.sectionLabel)
                    .lineLimit(1)
            } else if let categoryName {
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

            Text("Correct \(correctCount) · Wrong \(incorrectCount) · Skipped \(skippedCount)")
                .font(.hangsBody)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("completion.breakdown")
        }
    }

    /// #232 (4A): "Geography · quiz from a friend".
    @ViewBuilder private var friendsQuizLabel: some View {
        if let categoryName {
            Text("\(categoryName) · quiz from a friend")
        } else {
            Text("Quiz from a friend")
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
        VStack(alignment: .trailing, spacing: Theme.Hangs.Spacing.xxs) {
            HStack(alignment: .center, spacing: Theme.Hangs.Spacing.xs) {
                HangsSectionLabel(text: "Questions")
                Spacer(minLength: Theme.Hangs.Spacing.xs)
                if route == .recap {
                    summaryControl
                }
            }
            if route == .recap, viewModel.readAloudFailure == .recapSummary {
                ReadAloudFailureNote(identifier: "recap.playSummaryFailed")
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

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            // Founder round 4: the commands are shown wherever they work —
            // here "ďalší" starts the next quiz and "domov" goes Home.
            if viewModel.commandListenerHint != nil {
                ListenBar(
                    mode: .command,
                    feedback: viewModel.voiceFeedbackPhase,
                    recognizingWord: viewModel.recognizingWord,
                    heard: viewModel.commandHeard,
                    commandHint: viewModel.voiceHintWords,
                    language: viewModel.commandLanguage
                )
                .transition(.opacity)
            }

            VStack(spacing: Theme.Hangs.Spacing.xs) {
                mainButton
                homeButton
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.md)
    }

    /// #232 (4A): a friend's round is not played again; it is sent on.
    @ViewBuilder private var mainButton: some View {
        if isFriendsRound {
            HangsPrimaryButton(title: "Send to a friend", icon: "square.and.arrow.up", isLoading: share.isCreating, action: sendToFriend)
                .accessibilityIdentifier("\(route.idPrefix).sendToFriend")
        } else {
            playAgainButton
        }
    }

    private var playAgainButton: some View {
        HangsPrimaryButton(title: "Next quiz", trailingIcon: "arrow.right") {
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
