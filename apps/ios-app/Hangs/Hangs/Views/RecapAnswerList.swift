//
//  RecapAnswerList.swift
//  Hangs
//
//  The round's questions, one row each: the question, the right answer, and a
//  tap opens what the player said, the explanation and its source. On the
//  round end (#132 E) and, #251 (founder TF 2026-11-27: "chcel by som vidieť
//  aj zoznam otázok s odpoveďami"), on the daily challenge's round end.
//

import SwiftUI

struct RecapAnswerList: View {
    @ObservedObject var viewModel: QuizViewModel
    @State private var expandedEntryId: Int?
    @State private var sourceSheet: RecapSource?

    var body: some View {
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
                    hearItFailed: viewModel.readAloudFailure == .recapEntry(entry.id),
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

    private func toggle(_ id: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            expandedEntryId = expandedEntryId == id ? nil : id
        }
    }
}
