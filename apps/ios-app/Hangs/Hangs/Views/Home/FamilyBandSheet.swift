//
//  FamilyBandSheet.swift
//  Hangs
//
//  #236 — the age sheet "Pre aký vek?" (canvas F1): the first flip of Home to
//  the family mode asks for the band once; afterwards the Vek pill changes
//  it. One row per band with something to play, the line that the adult is
//  the one who answers, and that the age is kept.
//

import SwiftUI

struct FamilyBandSheet: View {
    @State private var contentHeight: CGFloat = Metrics.initialHeight

    let bands: [FamilyBand]
    let selected: FamilyBand?
    let onSelect: (FamilyBand) -> Void
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Hangs.Spacing.sm) {
                header
                Text("You answer, the kids guess along with you.")
                    .font(.hangsBody)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("family.band.adultAnswers")
                ForEach(bands, id: \.self) { band in
                    row(band)
                }
                Text("I'll remember the age. You can change it on Home.")
                    .font(.hangsCaption)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, Theme.Hangs.Spacing.lg)
            .padding(.top, Theme.Hangs.Spacing.xl)
            .padding(.bottom, Theme.Hangs.Spacing.md)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .background(Theme.Hangs.Colors.bgSheet.ignoresSafeArea())
        .presentationDetents([.height(contentHeight)])
        .accessibilityIdentifier("family.band.sheet")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Hangs.Spacing.sm) {
            Text("What age?")
                .font(.hangsTitle)
                .foregroundStyle(Theme.Hangs.Colors.ink)
                .hangsHeadlineFit()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            HangsNavChip(icon: "xmark", label: "Close", action: onClose)
                .accessibilityIdentifier("family.band.close")
        }
    }

    private func row(_ band: FamilyBand) -> some View {
        let isOn = band == selected
        return Button {
            onSelect(band)
        } label: {
            HStack(spacing: Theme.Hangs.Spacing.md) {
                Text(verbatim: band.label)
                    .font(.hangsTitle)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minWidth: Metrics.bandColumn, alignment: .leading)
                Text(band.summary)
                    .font(.hangsBody)
                    .foregroundStyle(Theme.Hangs.Colors.muted)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                checkMark(isOn: isOn)
            }
            .foregroundStyle(Theme.Hangs.Colors.ink)
            .padding(.horizontal, Theme.Hangs.Spacing.md)
            .padding(.vertical, Theme.Hangs.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card, style: .continuous)
                    .fill(Theme.Hangs.Colors.bgCard)
                    .strokeBorder(isOn ? Theme.Hangs.Colors.ink : Theme.Hangs.Colors.hairline, lineWidth: isOn ? Metrics.selectedBorder : 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(band.spokenLabel))
        .accessibilityValue(Text(band.summary))
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("family.band.\(band.rawValue)")
    }

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

    private enum Metrics {
        /// Until the first layout pass measures the content.
        static let initialHeight: CGFloat = 460
        /// Canvas F1: band rows are 80 pt, the band number column 84 pt.
        static let rowHeight: CGFloat = 80
        static let bandColumn: CGFloat = 84
        static let check: CGFloat = 24
        static let ringWidth: CGFloat = 2
        static let selectedBorder: CGFloat = 2
    }
}

#if DEBUG
    #Preview {
        Color.clear.sheet(isPresented: .constant(true)) {
            FamilyBandSheet(bands: FamilyBand.allCases, selected: .kids7to9, onSelect: { _ in }, onClose: {})
        }
    }
#endif
