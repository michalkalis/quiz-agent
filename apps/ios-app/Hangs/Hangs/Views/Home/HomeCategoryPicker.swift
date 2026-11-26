//
//  HomeCategoryPicker.swift
//  Hangs
//
//  #194 C1 — category picker. Multi-select stays (#82 decision 7): each row
//  toggles its category, "All Categories" clears the selection. #249.1: the
//  tiles became the shared vertical list (CategoryListView). Changes apply at once
//  (as in the beta menu); Done and the swipe only close the sheet.
//  #206: the "local questions" switch sits under the list (founder picked
//  variant B, 2026-10-22) — it shapes which questions come, like categories.
//

import SwiftUI

struct HomeCategoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var categories: [String]
    @Binding var includeLocalQuestions: Bool
    /// #242: the served extra categories, after the permanent ones.
    var extras: [ExtraCategory] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.md) {
                Text("Categories")
                    .font(.hangsTitle)
                    .foregroundStyle(Theme.Hangs.Colors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Theme.Hangs.Spacing.xxs)
                CategoryListView(categories: $categories, extras: extras)
                localQuestionsRow
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.top, Theme.Hangs.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .safeAreaBar(edge: .bottom) { doneButton }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .presentationDragIndicator(.hidden)
    }

    private var localQuestionsRow: some View {
        HangsToggleRow(
            label: "Questions for locals",
            subtitle: "Things only people who live in that country or city know. For example, bus and tram routes.",
            isOn: $includeLocalQuestions
        )
        .background(surface(cornerRadius: Theme.Hangs.Radius.card))
        .accessibilityIdentifier("home.categories.localQuestions")
    }

    private func surface(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.Hangs.Colors.bgCard)
            .strokeBorder(Theme.Hangs.Colors.hairline)
    }

    // MARK: - Done

    private var doneButton: some View {
        HangsPrimaryButton(title: "Done") { dismiss() }
            .accessibilityIdentifier("home.categories.done")
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.bottom, Theme.Hangs.Spacing.xs)
    }
}

#if DEBUG
    #Preview {
        @Previewable @State var categories = ["geography-world", "history"]
        @Previewable @State var includeLocal = true
        HomeCategoryPicker(categories: $categories, includeLocalQuestions: $includeLocal)
    }
#endif
