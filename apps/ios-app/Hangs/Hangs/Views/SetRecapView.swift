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

    var body: some View {
        VStack(spacing: 0) {
            HangsBrandRow {
                HangsNavChip(icon: "xmark") { viewModel.resetToHome() }
                    .accessibilityIdentifier("recap.close")
            }

            ScrollView {
                VStack(spacing: 0) {
                    hero
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    rowsList
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                }
                .padding(.bottom, 12)
            }

            ctaStack
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
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
            Text("SET RESULT · \(viewModel.recapEntries.first?.category ?? "")")
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

            HStack(spacing: 8) {
                chip(glyph: "✓", Text("\(correctCount) CORRECT"),
                     color: Theme.Hangs.Colors.successText,
                     fill: Theme.Hangs.Colors.greenSoft)
                chip(glyph: "✗", Text("\(missedCount) MISSED"),
                     color: Theme.Hangs.Colors.pinkText,
                     fill: Theme.Hangs.Colors.pinkSoft)
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
        HStack(spacing: 4) {
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

    private var rowsList: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.recapEntries) { entry in
                SetRecapRow(
                    entry: entry,
                    isExpanded: expandedEntryId == entry.id,
                    hearItDisabled: viewModel.settings.isMuted,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedEntryId = expandedEntryId == entry.id ? nil : entry.id
                        }
                    },
                    onHearIt: { viewModel.playRecapEntryExplanation(entry) }
                )
            }
        }
    }

    // MARK: - CTA stack

    private var ctaStack: some View {
        VStack(spacing: 8) {
            HangsPrimaryButton(
                title: viewModel.isNarratingRecap ? "Stop summary" : "Play summary",
                icon: viewModel.isNarratingRecap ? "stop.fill" : "speaker.wave.2.fill",
                height: 56
            ) {
                viewModel.toggleRecapNarration()
            }
            .disabled(viewModel.settings.isMuted)
            .opacity(viewModel.settings.isMuted ? 0.5 : 1)
            .accessibilityIdentifier("recap.playSummary")

            HStack(spacing: 8) {
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
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }
}

// MARK: - Row

/// One recap row. Collapsed: badge + 2-line stem + the revealed answer +
/// chevron (the answer is visible without expanding — variant C's whole
/// point is glanceability). Expanded: "you said" (struck through — it was
/// wrong), explanation, hear-it.
struct SetRecapRow: View {
    let entry: RecapEntry
    let isExpanded: Bool
    let hearItDisabled: Bool
    let onToggle: () -> Void
    let onHearIt: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                collapsedRow
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expandedSection
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.Hangs.Colors.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Theme.Hangs.Colors.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("recap.row.\(entry.id)")
    }

    private var collapsedRow: some View {
        HStack(spacing: 12) {
            badge

            Text(entry.questionText)
                .font(.hangsBody(13, weight: .medium))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            Text(entry.correctAnswerDisplay)
                .textCase(.uppercase)
                .font(.hangsMono(11, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 120, alignment: .trailing)

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
        .frame(width: 22, height: 22)
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
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Theme.Hangs.Colors.hairline)
                .frame(height: 1)
                .padding(.top, 12)
                .padding(.bottom, 4)

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
                        Image(systemName: "speaker.wave.2.fill")
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
        }
    }
}
