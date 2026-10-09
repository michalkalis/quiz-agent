//
//  HomeCategoryPicker.swift
//  Hangs
//
//  #194 C1 — category picker (canvas Bg-Topics, Zábava decided in
//  Dec-Zabava-Topics). Multi-select stays (#82 decision 7): each tile toggles
//  its category, "All Categories" clears the selection. Changes apply at once
//  (as in the beta menu); Done and the swipe only close the sheet.
//

import SwiftUI

struct HomeCategoryPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var categories: [String]

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
                allCategoriesRow
                LazyVGrid(columns: columns, spacing: Theme.Hangs.Spacing.sm) {
                    ForEach(Config.categoryOptions.compactMap(\.id), id: \.self) { id in
                        tile(id)
                    }
                }
            }
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.top, Theme.Hangs.Spacing.xl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) { doneBar }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .presentationDragIndicator(.hidden)
    }

    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: Theme.Hangs.Spacing.sm), count: count)
    }

    // MARK: - Rows

    private var allCategoriesRow: some View {
        Button(action: selectAll) {
            HStack(spacing: Theme.Hangs.Spacing.md) {
                HStack(spacing: 0) {
                    ForEach(Theme.Hangs.Category.taxonomy, id: \.self) { id in
                        Theme.Hangs.Category.style(for: id).fill
                    }
                }
                .frame(width: Metrics.stripWidth, height: Metrics.stripHeight)
                .clipShape(Capsule())
                .accessibilityHidden(true)
                Text(verbatim: Config.categoryOptions.first { $0.id == nil }?.display ?? "")
                    .font(.hangsLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                checkMark(isOn: categories.isEmpty, style: nil)
            }
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
            .background(surface(cornerRadius: Theme.Hangs.Radius.card))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(categories.isEmpty ? .isSelected : [])
        .accessibilityIdentifier("home.category.all")
    }

    private func tile(_ id: String) -> some View {
        let isOn = categories.contains(id)
        let style = Theme.Hangs.Category.style(for: id)
        return Button {
            toggle(id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.xs) {
                checkMark(isOn: isOn, style: style)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Spacer(minLength: 0)
                Text(verbatim: Config.categoryDisplayName(for: id))
                    .font(.hangsLabel)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isOn ? style.text : Theme.Hangs.Colors.ink)
            .padding(EdgeInsets(top: Theme.Hangs.Spacing.sm, leading: Theme.Hangs.Spacing.md, bottom: Theme.Hangs.Spacing.md, trailing: Theme.Hangs.Spacing.sm))
            .frame(maxWidth: .infinity, minHeight: Metrics.tileHeight, alignment: .topLeading)
            .background {
                if isOn {
                    RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                        .fill(style.fill)
                } else {
                    surface(cornerRadius: Theme.Hangs.Radius.card)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("home.category.\(id)")
    }

    /// Filled check in the tile's text colour when on, an empty ring when off.
    private func checkMark(isOn: Bool, style: Theme.Hangs.Category.Style?) -> some View {
        let ink = style?.text ?? Theme.Hangs.Colors.ink
        let glyph = style?.fill ?? Theme.Hangs.Colors.bgCard
        return ZStack {
            if isOn {
                Circle().fill(ink)
                Image(systemName: "checkmark")
                    .font(.hangsCaption.weight(.bold))
                    .foregroundStyle(glyph)
            } else {
                Circle().strokeBorder(Theme.Hangs.Colors.track, lineWidth: Metrics.ringWidth)
            }
        }
        .frame(width: Metrics.check, height: Metrics.check)
        .accessibilityHidden(true)
    }

    private func surface(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.Hangs.Colors.bgCard)
            .strokeBorder(Theme.Hangs.Colors.hairline)
    }

    // MARK: - Done bar

    private var doneBar: some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            Group {
                if !categories.isEmpty {
                    Text("\(categories.count) selected")
                }
            }
            .font(.hangsLabel)
            .foregroundStyle(Theme.Hangs.Colors.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Done") { dismiss() }
                .font(.hangsLabel)
                .foregroundStyle(Theme.Hangs.Colors.textOnAction)
                .padding(.horizontal, Theme.Hangs.Spacing.xl)
                .frame(minHeight: Metrics.doneHeight)
                .background(Capsule().fill(Theme.Hangs.Colors.action))
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.categories.done")
        }
        .padding(.leading, Theme.Hangs.Spacing.lg)
        .padding(.trailing, Theme.Hangs.Spacing.xs)
        .padding(.vertical, Theme.Hangs.Spacing.xs)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .padding(.bottom, Theme.Hangs.Spacing.xs)
    }

    // MARK: - Actions

    private func selectAll() {
        categories = []
    }

    private func toggle(_ id: String) {
        if let index = categories.firstIndex(of: id) {
            categories.remove(at: index)
        } else {
            categories.append(id)
        }
    }

    private enum Metrics {
        static let rowHeight: CGFloat = 60
        static let tileHeight: CGFloat = 100
        static let check: CGFloat = 24
        static let ringWidth: CGFloat = 2
        static let stripWidth: CGFloat = 42
        static let stripHeight: CGFloat = 12
        static let doneHeight: CGFloat = 52
    }
}

#if DEBUG
    #Preview {
        @Previewable @State var categories = ["geography-world", "history"]
        HomeCategoryPicker(categories: $categories)
    }
#endif
