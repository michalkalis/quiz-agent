//
//  OrderProgressView.swift
//  Hangs
//
//  Live status of a custom-pack order (issue #95). Observes OrderPackViewModel
//  through the create → poll → delivered/failed lifecycle. On delivery it offers
//  a "Start quiz" CTA that plays the freshly generated pack.
//

import SwiftUI

struct OrderProgressView: View {
    @ObservedObject var viewModel: OrderPackViewModel
    /// Play the delivered pack by its packId (see ContentView routing note in
    /// SettingsView.playPack).
    let onPlayPack: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                switch viewModel.state {
                case .editing, .submitting:
                    workingCard(
                        title: "Submitting your order…",
                        detail: nil,
                        progress: nil
                    )
                case .polling(let snapshot):
                    workingCard(
                        title: "Building your pack…",
                        detail: statusDetail(for: snapshot),
                        progress: snapshot.job.map { Double($0.progress) / 100 }
                    )
                case .delivered(let snapshot):
                    deliveredCard(snapshot)
                case .failed(let message):
                    failedCard(message)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .background(Theme.Hangs.Colors.bg.ignoresSafeArea())
        .navigationTitle("Your pack")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { viewModel.stop() }
    }

    // MARK: - Cards

    private func workingCard(title: LocalizedStringKey, detail: String?, progress: Double?) -> some View {
        HangsCard(padding: EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)) {
            VStack(spacing: 16) {
                ProgressView()
                    .tint(Theme.Hangs.Colors.pink)
                Text(title)
                    .font(.hangsBody(17, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.ink)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.hangsMono(13, weight: .medium))
                        .foregroundColor(Theme.Hangs.Colors.muted)
                        .multilineTextAlignment(.center)
                }
                if let progress {
                    ProgressView(value: progress)
                        .tint(Theme.Hangs.Colors.blue)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func deliveredCard(_ snapshot: OrderSnapshot) -> some View {
        VStack(spacing: 20) {
            HangsCard(padding: EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)) {
                VStack(spacing: 12) {
                    HangsResultBanner(kind: .correct)
                    Text("Your pack is ready")
                        .font(.hangsBody(18, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                }
                .frame(maxWidth: .infinity)
            }

            if let packId = snapshot.packId {
                HangsPrimaryButton(title: "Start quiz", icon: "play.fill") {
                    onPlayPack(packId)
                }
                .accessibilityIdentifier("orderProgress.startQuiz")
            }
        }
    }

    private func failedCard(_ message: String) -> some View {
        VStack(spacing: 20) {
            HangsCard(padding: EdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)) {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.error)
                    Text(verbatim: message)
                        .font(.hangsBody(16))
                        .foregroundColor(Theme.Hangs.Colors.ink)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            }

            HangsSecondaryButton(title: "Back", icon: "chevron.left") {
                dismiss()
            }
            .accessibilityIdentifier("orderProgress.back")
        }
    }

    private func statusDetail(for snapshot: OrderSnapshot) -> String {
        if let job = snapshot.job {
            return "\(snapshot.status) · \(job.status) \(job.progress)%"
        }
        return snapshot.status
    }
}

#if DEBUG
    #Preview {
        NavigationStack {
            OrderProgressView(
                viewModel: OrderPackViewModel(service: MockPackOrderService()),
                onPlayPack: { _ in }
            )
        }
    }
#endif
