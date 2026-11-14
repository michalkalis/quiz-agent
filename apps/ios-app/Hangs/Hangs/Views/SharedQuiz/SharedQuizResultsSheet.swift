//
//  SharedQuizResultsSheet.swift
//  Hangs
//
//  #232: the comparison of a link that is not played (again): the sender
//  opening their own link to see how friends did, or a friend opening one
//  already played. The same ranking as on the round end (4A).
//

import SwiftUI

struct SharedQuizResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var share: SharedQuizShareModel

    init(network: NetworkServiceProtocol, token: String) {
        _share = StateObject(wrappedValue: SharedQuizShareModel(network: network, source: nil, token: token, displayName: nil))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
            HStack {
                Text("Quiz results")
                    .font(.hangsHeading)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done") { dismiss() }
                    .font(.hangsButton)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("sharedQuiz.results.done")
            }
            ScrollView {
                if share.loadFailed {
                    Text(verbatim: SharedQuizUnavailable.notFound.message)
                        .font(.hangsBody)
                        .foregroundStyle(Theme.Hangs.Colors.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if share.rows.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Hangs.Spacing.xl)
                } else {
                    SharedQuizRankingCard(rows: share.rows)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(Theme.Hangs.Spacing.md)
        .presentationDetents([.medium, .large])
        .background(Theme.Hangs.Colors.bgSheet)
        .task { await share.loadResults().value }
    }
}
