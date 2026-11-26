//
//  CategoryListView.swift
//  Hangs
//
//  #249.1 — the category choice as one calm vertical list: "All Categories" on
//  top, then one full-width row per category, name left, selection right.
//  Shared by the solo picker (HomeCategoryPicker) and the together game's
//  "What we play" sheet, so both read and behave the same. Multi-select: a row
//  toggles its category, "All Categories" clears the selection.
//

import SwiftUI

struct CategoryListView: View {
    @Environment(\.locale) private var locale
    @Binding var categories: [String]
    /// #242: the served extra categories, after the permanent ones.
    var extras: [ExtraCategory] = []
    /// False while something else is chosen (a pack in the together game):
    /// no row shows as selected, a tap still picks categories.
    var showsSelection = true

    var body: some View {
        VStack(spacing: 0) {
            row(
                name: Config.categoryOptions.first { $0.id == nil }?.display ?? "",
                detail: nil,
                isOn: showsSelection && categories.isEmpty,
                id: "all",
                action: { categories = [] }
            )
            ForEach(Config.categoryOptions.compactMap(\.id), id: \.self) { id in
                HangsDivider()
                row(
                    name: Config.categoryDisplayName(for: id) ?? "",
                    detail: nil,
                    isOn: isOn(id),
                    id: id,
                    action: { toggle(id) }
                )
            }
            ForEach(extras) { extra in
                HangsDivider()
                row(name: extra.name, detail: extraDetail(extra), isOn: isOn(extra.key), id: extra.key, action: { toggle(extra.key) })
            }
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                .fill(Theme.Hangs.Colors.bgCard)
                .strokeBorder(Theme.Hangs.Colors.hairline)
        )
    }

    private func isOn(_ id: String) -> Bool {
        showsSelection && categories.contains(id)
    }

    /// "New · until 22 Dec" as a small gray line, "New" when no end is announced.
    private func extraDetail(_ extra: ExtraCategory) -> Text {
        if let until = extra.untilLabel(locale: locale) {
            Text("New · until \(until)")
        } else {
            Text("New")
        }
    }

    private func row(name: String, detail: Text?, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
        // a11y-id: set below from `id`
        Button(action: action) {
            HStack(spacing: Theme.Hangs.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xxs) {
                    Text(verbatim: name)
                        .font(.hangsLabel)
                        .foregroundStyle(Theme.Hangs.Colors.ink)
                        .multilineTextAlignment(.leading)
                    if let detail {
                        detail
                            .font(.hangsCaption)
                            .foregroundStyle(Theme.Hangs.Colors.muted)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                checkMark(isOn: isOn)
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("home.category.\(id)")
    }

    /// Filled check when on, an empty ring when off.
    private func checkMark(isOn: Bool) -> some View {
        ZStack {
            if isOn {
                Circle().fill(Theme.Hangs.Colors.ink)
                Image(systemName: "checkmark")
                    .font(.hangsCaption.weight(.bold))
                    .foregroundStyle(Theme.Hangs.Colors.bgCard)
            } else {
                Circle().strokeBorder(Theme.Hangs.Colors.track, lineWidth: Metrics.ringWidth)
            }
        }
        .frame(width: Metrics.check, height: Metrics.check)
        .accessibilityHidden(true)
    }

    private func toggle(_ id: String) {
        if let index = categories.firstIndex(of: id) {
            categories.remove(at: index)
        } else {
            categories.append(id)
        }
    }

    private enum Metrics {
        static let rowHeight: CGFloat = 56
        static let check: CGFloat = 24
        static let ringWidth: CGFloat = 2
    }
}

#if DEBUG
    #Preview {
        @Previewable @State var categories = ["geography-world", "history"]
        CategoryListView(
            categories: $categories,
            extras: [ExtraCategory(key: "extra-decades", name: "Decades and music", until: "2026-12-22")]
        )
        .padding()
    }
#endif
