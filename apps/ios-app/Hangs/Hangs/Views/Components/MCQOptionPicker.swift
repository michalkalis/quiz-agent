//
//  MCQOptionPicker.swift
//  Hangs
//
//  Multiple choice option picker with driving-safe tap targets.
//  Renders each option via the reusable 4-state `AnswerOption` (issue #45, 45.5).
//

import SwiftUI

struct MCQOptionPicker: View {
    let options: [(key: String, value: String)]
    /// #185 track G: key → badge label from the server (`Question.optionLabels`);
    /// a key without one keeps its legacy letter.
    let labels: [String: String]
    let onSelect: (String, String) -> Void
    /// The single VM-owned selection key (#110 T4 — was a view-local `@State`
    /// with local-wins precedence over the voice-matched key, which let a tap
    /// and a voice match disagree on what was highlighted vs. submitted). The
    /// tap path below writes through this binding, so highlight and submission
    /// always read the same value.
    @Binding var externalSelectedKey: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// #125: SE-class shrinks the grid tiles + gaps (driven by container height).
    var compact: Bool = false

    /// #174: an answer (or a skip) is in flight with nothing covering the screen.
    /// The chosen option spins in place; the rest dim and stop taking taps — the
    /// full-screen evaluating overlay that used to do both is gone.
    var isSubmitting: Bool = false

    init(
        options: [(key: String, value: String)],
        labels: [String: String]? = nil,
        onSelect: @escaping (String, String) -> Void,
        externalSelectedKey: Binding<String?> = .constant(nil),
        compact: Bool = false,
        isSubmitting: Bool = false
    ) {
        self.options = options
        self.labels = labels ?? [:]
        self.onSelect = onSelect
        _externalSelectedKey = externalSelectedKey
        self.compact = compact
        self.isSubmitting = isSubmitting
    }

    /// 80pt for the 2-option T/F variant; 64pt for all other MCQ rows. (The 4-up
    /// grid uses `AnswerTile`'s own 88/76pt floor, not this.)
    var optionMinHeight: CGFloat { options.count == 2 ? 80 : 64 }

    /// #174 C2: the longest option a half-width tile can hold at full size.
    /// Above it the grid shrinks and ellipsises the text (HIG calls a truncated
    /// label an error state) — Slovak options run 6–10 words routinely.
    static let gridMaxOptionLength = 24

    /// #125 Variant A gave 4 options a 2×2 grid unconditionally. #174 C2 makes
    /// that conditional on the text fitting: EVERY option short → grid, otherwise
    /// the full-width rows. The 2-option T/F variant stays on rows either way
    /// (locked #125 decision — the grid is for 4 options only).
    var usesGrid: Bool {
        options.count != 2 && options.allSatisfy { $0.value.count <= Self.gridMaxOptionLength }
    }

    /// #188 G9 (D8): the largest text size a half-width tile holds a single word
    /// at. Above it the grid broke words mid-letter ("Budapes / t"), so the set
    /// moves to full-width rows.
    static let gridMaxTypeSize: DynamicTypeSize = .xLarge

    /// The layout actually drawn: the length rule above AND the text-size rule.
    /// Pure so it is assertable without rendering.
    func usesGrid(at size: DynamicTypeSize) -> Bool {
        usesGrid && size <= Self.gridMaxTypeSize
    }

    @ViewBuilder
    var body: some View {
        if usesGrid(at: dynamicTypeSize) {
            optionGrid
        } else {
            optionRows
        }
    }

    /// Full-width AnswerOption rows — the T/F path, and now the long-option path
    /// too.
    private var optionRows: some View {
        // #174 C2: this path now carries four rows, not just the T/F pair — a
        // short container tightens the gaps so they still fit above the fold.
        // #194 R-MCQ: one 8pt gap for rows and tiles alike — content first.
        VStack(spacing: Theme.Hangs.Spacing.xs) {
            ForEach(options, id: \.key) { option in
                AnswerOption(
                    key: option.key,
                    value: option.value,
                    label: labels[option.key],
                    state: externalSelectedKey == option.key ? .selected : .default,
                    isLoading: isLoading(option.key),
                    minHeight: optionMinHeight,
                    action: { tapOption(option) }
                )
                .disabled(externalSelectedKey != nil || isSubmitting)
                .opacity(isDimmed(option.key) ? 0.45 : 1)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15),
                    value: externalSelectedKey
                )
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
    }

    private var gridGap: CGFloat { Theme.Hangs.Spacing.xs }

    private var optionGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: gridGap),
                GridItem(.flexible(), spacing: gridGap),
            ],
            spacing: gridGap
        ) {
            ForEach(options, id: \.key) { option in
                AnswerTile(
                    key: option.key,
                    value: option.value,
                    label: labels[option.key],
                    state: externalSelectedKey == option.key ? .selected : .default,
                    isLoading: isLoading(option.key),
                    compact: compact,
                    action: { tapOption(option) }
                )
                .disabled(externalSelectedKey != nil || isSubmitting)
                .opacity(isDimmed(option.key) ? 0.45 : 1)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15),
                    value: externalSelectedKey
                )
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
    }

    /// The chosen option is the only one that spins; a skip has no chosen option
    /// and so spins nothing here (its own chip carries that state).
    private func isLoading(_ key: String) -> Bool { isSubmitting && externalSelectedKey == key }

    /// Everything the driver can no longer act on recedes while a submit is in flight.
    private func isDimmed(_ key: String) -> Bool { isSubmitting && externalSelectedKey != key }

    /// Shared tap handler (both the rows and the grid). The answer goes to the
    /// view model AT the tap: a 500 ms grace before `onSelect` (54.16) left the
    /// quiz in `.recording` after the driver had answered, so the speech-start
    /// window, VAD or the cap could still end that recording first, upload it
    /// and open the voice sheet, and the late tap then found `.processing` and
    /// was dropped (RS-10 flake). The tapped tile is the feedback now (#174:
    /// it spins in place), so the grace bought nothing.
    private func tapOption(_ option: (key: String, value: String)) {
        guard externalSelectedKey == nil else { return }
        externalSelectedKey = option.key
        onSelect(option.key, option.value)
    }
}

#if DEBUG
    #Preview {
        MCQOptionPicker(
            options: [
                (key: "a", value: "Mars"),
                (key: "b", value: "Jupiter"),
                (key: "c", value: "Saturn"),
                (key: "d", value: "Neptune"),
            ],
            onSelect: { key, value in
                print("Selected \(key): \(value)")
            }
        )
        .background(Theme.Hangs.Colors.bg)
    }
#endif
