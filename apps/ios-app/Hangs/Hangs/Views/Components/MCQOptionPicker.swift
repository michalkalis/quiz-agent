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
    let onSelect: (String, String) -> Void
    /// Voice-matched key from the ViewModel (45.9) — drives `selected` without a tap.
    var externalSelectedKey: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedKey: String?

    private var effectiveSelectedKey: String? { selectedKey ?? externalSelectedKey }
    /// 80pt for the 2-option T/F variant; 64pt for all other MCQ lists.
    var optionMinHeight: CGFloat { options.count == 2 ? 80 : 64 }

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            ForEach(options, id: \.key) { option in
                AnswerOption(
                    key: option.key,
                    value: option.value,
                    state: effectiveSelectedKey == option.key ? .selected : .default,
                    minHeight: optionMinHeight,
                    action: {
                        guard effectiveSelectedKey == nil else { return }
                        selectedKey = option.key
                        submitAfterDelay(key: option.key, value: option.value)
                    }
                )
                .disabled(effectiveSelectedKey != nil)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15),
                    value: selectedKey
                )
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
    }

    private func submitAfterDelay(key: String, value: String) {
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            onSelect(key, value)
        }
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
