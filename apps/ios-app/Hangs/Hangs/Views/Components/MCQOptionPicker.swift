//
//  MCQOptionPicker.swift
//  Hangs
//
//  Multiple choice option picker with driving-safe tap targets.
//  Renders each option via the reusable 4-state `AnswerOption` (issue #45, 45.5).
//

import SwiftUI

/// Holds the delayed tap-submit task (54.16). A reference type (kept in @State) so
/// the voice-match onChange cancels the exact task the tap scheduled, and so the
/// single-submit guard is unit-testable without SwiftUI state machinery.
@MainActor
final class MCQDelayedSubmit {
    private var task: Task<Void, Never>?
    /// The key this in-flight submit will fire for (#110 T4 cancel-semantics
    /// rework) — lets the owner tell its own tap echo (the VM key becoming this
    /// same value) apart from an other-source supersede (a different key arrives).
    private(set) var pendingKey: String?

    func schedule(key: String? = nil, delayNs: UInt64 = 500_000_000, _ fire: @escaping @MainActor () -> Void) {
        pendingKey = key
        task = Task {
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            fire()
            pendingKey = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        pendingKey = nil
    }
}

struct MCQOptionPicker: View {
    let options: [(key: String, value: String)]
    let onSelect: (String, String) -> Void
    /// The single VM-owned selection key (#110 T4 — was a view-local `@State`
    /// with local-wins precedence over the voice-matched key, which let a tap
    /// and a voice match disagree on what was highlighted vs. submitted). The
    /// tap path below writes through this binding, so highlight and submission
    /// always read the same value.
    @Binding var externalSelectedKey: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pending tap submit (54.16) — a concurrent voice match cancels it; the VM
    /// submits voice matches itself, so letting both run fired onSelect twice.
    @State private var pendingSubmit = MCQDelayedSubmit()

    init(
        options: [(key: String, value: String)],
        onSelect: @escaping (String, String) -> Void,
        externalSelectedKey: Binding<String?> = .constant(nil)
    ) {
        self.options = options
        self.onSelect = onSelect
        _externalSelectedKey = externalSelectedKey
    }

    /// 80pt for the 2-option T/F variant; 64pt for all other MCQ lists.
    var optionMinHeight: CGFloat { options.count == 2 ? 80 : 64 }

    var body: some View {
        VStack(spacing: Theme.Hangs.Spacing.sm) {
            ForEach(options, id: \.key) { option in
                AnswerOption(
                    key: option.key,
                    value: option.value,
                    state: externalSelectedKey == option.key ? .selected : .default,
                    minHeight: optionMinHeight,
                    action: {
                        guard externalSelectedKey == nil else { return }
                        // Schedule before writing the key, so the in-flight
                        // pendingKey is already set before this write can be
                        // observed by the onChange below (self-echo below).
                        submitAfterDelay(key: option.key, value: option.value)
                        externalSelectedKey = option.key
                    }
                )
                .disabled(externalSelectedKey != nil)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.15),
                    value: externalSelectedKey
                )
            }
        }
        .padding(.horizontal, Theme.Hangs.Spacing.md)
        .onChange(of: externalSelectedKey) { _, newValue in
            // #110 T4 cancel-semantics rework: now that the tap writes this same
            // key, this fires on the tap's own echo too. Only cancel on an
            // other-source supersede (a different key arriving — e.g. a voice
            // match overriding a pending tap); never on the tap's own echo, and
            // never on nil (the VM clears this key on a new question). A voice
            // match on the SAME key as a pending tap never fires this at all
            // (no value change) — that duplicate is absorbed by the entry guard
            // in `submitMCQAnswer` (answers are legal only from
            // .askingQuestion/.recording), not here.
            guard let newValue else { return }
            guard newValue != pendingSubmit.pendingKey else { return }
            pendingSubmit.cancel()
        }
    }

    private func submitAfterDelay(key: String, value: String) {
        pendingSubmit.schedule(key: key) {
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
