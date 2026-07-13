//
//  OrderPackView.swift
//  Hangs
//
//  Custom-pack order form (issue #95). Admin-gated entry from Settings. Reuses
//  the existing Hangs building blocks — no new design system. On submit it pushes
//  OrderProgressView, which observes the same view model through delivery.
//

import SwiftUI

struct OrderPackView: View {
    @StateObject private var viewModel: OrderPackViewModel
    /// Play the delivered pack (packId). Threaded through to OrderProgressView.
    private let onPlayPack: (String) -> Void

    @State private var showProgress = false

    /// Supported order languages (wire values en/sk/cs).
    private static let languages: [(code: String, name: LocalizedStringKey)] = [
        ("en", "English"),
        ("sk", "Slovak"),
        ("cs", "Czech"),
    ]

    init(service: PackOrderServiceProtocol, onPlayPack: @escaping (String) -> Void) {
        _viewModel = StateObject(wrappedValue: OrderPackViewModel(service: service))
        self.onPlayPack = onPlayPack
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                promptGroup
                languageGroup
                detailsGroup

                HangsPrimaryButton(
                    title: "Create pack",
                    icon: "sparkles"
                ) {
                    showProgress = true
                    Task { await viewModel.submit() }
                }
                .disabled(!viewModel.isValid)
                .opacity(viewModel.isValid ? 1 : 0.5)
                .accessibilityIdentifier("orderPack.submit")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .navigationTitle("Create pack")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showProgress) {
            OrderProgressView(viewModel: viewModel, onPlayPack: onPlayPack)
        }
    }

    // MARK: - Groups

    private var promptGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HangsSectionLabel(text: "prompt", color: Theme.Hangs.Colors.pink)
                .padding(.leading, 4)
            HangsCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        "Describe the quiz you want",
                        text: $viewModel.prompt,
                        axis: .vertical
                    )
                    .lineLimit(3...8)
                    .font(.hangsBody(16))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .accessibilityIdentifier("orderPack.prompt")

                    Text(verbatim: "\(viewModel.trimmedPromptCount) / \(OrderPackViewModel.maxPromptLength)")
                        .font(.hangsMono(12, weight: .medium))
                        .foregroundColor(viewModel.isValid ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.pink)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            Text("Between 10 and 1000 characters.")
                .font(.hangsBody(12))
                .foregroundColor(Theme.Hangs.Colors.muted)
                .padding(.leading, 4)
        }
    }

    private var languageGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HangsSectionLabel(text: "language", color: Theme.Hangs.Colors.blue)
                .padding(.leading, 4)
            HangsCard {
                Picker("Language", selection: $viewModel.language) {
                    ForEach(Self.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityIdentifier("orderPack.language")
            }
        }
    }

    private var detailsGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HangsSectionLabel(text: "optional", color: Theme.Hangs.Colors.accentTeal)
                .padding(.leading, 4)
            HangsCard {
                VStack(spacing: 0) {
                    TextField("Category", text: $viewModel.category)
                        .font(.hangsBody(16))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .accessibilityIdentifier("orderPack.category")

                    Rectangle()
                        .fill(Theme.Hangs.Colors.hairline)
                        .frame(height: 1)
                        .padding(.leading, 18)

                    TextField("Theme", text: $viewModel.theme)
                        .font(.hangsBody(16))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .accessibilityIdentifier("orderPack.theme")
                }
            }
        }
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            OrderPackView(service: MockPackOrderService(), onPlayPack: { _ in })
        }
    }
#endif
