//
//  RoomQuestionView.swift
//  Hangs
//
//  #212: everyone's question screen: tap A–D or type, then the answer locks.
//

import SwiftUI

struct RoomQuestionView: View {
    @ObservedObject var viewModel: RoomViewModel
    @FocusState private var typing: Bool

    var body: some View {
        // The countdown and the answer controls follow the server's time left.
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            VStack(spacing: Theme.Hangs.Spacing.sm) {
                if let round = viewModel.round {
                    HangsQuizProgressHeader(current: round.number, total: viewModel.state?.maxQuestions ?? round.number)
                    statusRow(round)
                    if let question = viewModel.question {
                        questionCard(question)
                        countdown
                        answerArea(question, round: round)
                    }
                    Spacer(minLength: 0)
                    footer(round)
                }
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.bottom, Theme.Hangs.Spacing.md)
        }
        .onChange(of: viewModel.round?.yourAnswer) { _, answer in
            if answer != nil { typing = false }
        }
    }

    // MARK: - Sections

    private func statusRow(_ round: RoomState.Round) -> some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            if viewModel.isHost {
                Text("Answered: \(round.answered.count)/\(viewModel.players.count)")
                    .accessibilityIdentifier("room.question.answered")
            } else if let me = viewModel.me {
                RoomPlayerAvatar(name: me.displayName, color: me.color, size: 24)
                Text(verbatim: me.displayName)
                Text("· Points: \(Self.points(me.score))")
            }
            Spacer(minLength: Theme.Hangs.Spacing.xs)
            if round.phase == .reading {
                Label(viewModel.isHost ? "Reading aloud" : "The host is reading aloud", systemImage: "speaker.wave.2")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .accessibilityIdentifier("room.question.reading")
            }
        }
        .font(.hangsLabel)
        .foregroundStyle(Theme.Hangs.Colors.ink)
    }

    private func questionCard(_ question: Question) -> some View {
        let identity = DeckIdentity(category: question.category, packId: nil)
        return HangsDeckCard(
            style: identity.style,
            categoryName: identity.chipName,
            categoryIdentifier: "question.category"
        ) {
            ScrollView {
                Text(question.question)
                    .font(.hangsTitle)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("question.text")
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxHeight: Metrics.cardMaxHeight)
    }

    @ViewBuilder
    private var countdown: some View {
        if let left = viewModel.secondsLeft() {
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                ProgressView(value: Double(left), total: Double(viewModel.answerWindowSeconds ?? max(left, 1)))
                    .tint(left <= Metrics.hurrySeconds ? Theme.Hangs.Colors.warning : Theme.Hangs.Colors.live)
                Text("\(left) s")
                    .font(.hangsMonoValue)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("room.question.timer")
            }
            .frame(minHeight: Metrics.countdownHeight)
        }
    }

    @ViewBuilder
    private func answerArea(_ question: Question, round: RoomState.Round) -> some View {
        if let answer = viewModel.yourAnswerText, round.yourAnswer != nil {
            lockedCard(answer)
        } else if question.isMultipleChoice {
            MCQOptionPicker(
                options: question.sortedAnswerOptions,
                labels: question.optionLabels,
                onSelect: { key, _ in Task { await viewModel.submitOption(key: key) } },
                externalSelectedKey: .constant(viewModel.submittingAnswer),
                isSubmitting: viewModel.submittingAnswer != nil
            )
            .disabled(!viewModel.canAnswer)
        } else {
            typedAnswerField
        }
    }

    private var typedAnswerField: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            TextField("Type your answer", text: $viewModel.typedAnswer)
                .font(.hangsBodyLG)
                .submitLabel(.send)
                .focused($typing)
                .onSubmit { Task { await viewModel.submitTypedAnswer() } }
                .padding(Theme.Hangs.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Hangs.Radius.cardInner, style: .continuous)
                        .fill(Theme.Hangs.Colors.bgCard)
                )
                .accessibilityIdentifier("room.answer.field")
            Button {
                Task { await viewModel.submitTypedAnswer() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.hangsBody(Metrics.sendIcon, weight: .bold))
                    .foregroundStyle(Theme.Hangs.Colors.textOnAction)
                    .frame(width: Metrics.sendSide, height: Metrics.sendSide)
                    .background(Circle().fill(Theme.Hangs.Colors.action))
            }
            .buttonStyle(.plain)
            .disabled(PlayerNameStore.cleaned(viewModel.typedAnswer) == nil)
            .accessibilityLabel(Text("Send answer"))
            .accessibilityIdentifier("room.answer.send")
        }
        .disabled(!viewModel.canAnswer)
    }

    private func lockedCard(_ answer: String) -> some View {
        HangsCard {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                Label("Answer locked", systemImage: "lock.fill")
                    .font(.hangsLabel)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                Text(verbatim: answer)
                    .font(.hangsBodyLG)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                Text("The others see it after the question.")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
            }
            .padding(Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("room.answer.locked")
    }

    @ViewBuilder
    private func footer(_ round: RoomState.Round) -> some View {
        if viewModel.isHost, viewModel.settings.readsAloud {
            HangsSecondaryButton(title: "Read again", icon: "arrow.counterclockwise") {
                viewModel.readAgain()
            }
            .disabled(viewModel.isReadingAloud)
            .accessibilityIdentifier("room.readAgain")
        } else if round.yourAnswer == nil, viewModel.secondsLeft() == 0 {
            Text("Time's up")
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.muted)
                .accessibilityIdentifier("room.question.timeUp")
        } else if round.yourAnswer == nil {
            Text("The others see your answer after the question.")
                .font(.hangsCaption)
                .foregroundStyle(Theme.Hangs.Colors.muted)
        }
    }

    static func points(_ score: Double) -> String {
        score.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    private enum Metrics {
        /// The options stay in view under a long question.
        static let cardMaxHeight: CGFloat = 260
        static let countdownHeight: CGFloat = 32
        static let sendSide: CGFloat = 52
        static let sendIcon: CGFloat = 18
        /// The bar turns amber for the last seconds.
        static let hurrySeconds = 5
    }
}
