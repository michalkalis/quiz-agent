//
//  ImageQuestionView.swift
//  CarQuiz
//
//  Displays an image-based question with AsyncImage above question text
//

import SwiftUI

struct ImageQuestionView: View {
    let question: Question

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            // Image (primary content)
            if let mediaUrl = question.mediaUrl, let url = URL(string: mediaUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 280)
                            .cornerRadius(Theme.Radius.lg)
                    case .failure:
                        // Silent placeholder — quiz continues via TTS
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .fill(Theme.Colors.bgCard)
                            .frame(height: 200)
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 40))
                                    .foregroundColor(Theme.Colors.textSecondary.opacity(0.4))
                            )
                    case .empty:
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .fill(Theme.Colors.bgCard)
                            .frame(height: 200)
                            .overlay(
                                ProgressView()
                                    .tint(Theme.Colors.accentPrimary)
                            )
                    @unknown default:
                        EmptyView()
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
            }

            // Question text (always visible — fallback for driving mode)
            Text(question.question)
                .font(.system(size: Theme.Typography.sizeLG, weight: .bold))
                .foregroundColor(Theme.Colors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity)
                .background(Theme.Colors.bgCard)
                .cornerRadius(Theme.Radius.xl)
                .padding(.horizontal, Theme.Spacing.md)
        }
    }
}

#if DEBUG
#Preview {
    ImageQuestionView(question: .previewImage)
        .background(Theme.Colors.bgPrimary)
}
#endif
