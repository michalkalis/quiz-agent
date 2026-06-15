//
//  ImageQuestionView.swift
//  Hangs
//
//  Displays an image-based question with AsyncImage above question text
//

import SwiftUI

struct ImageQuestionView: View {
    let question: Question

    private var imageAccessibilityLabel: String {
        if let subtype = question.imageSubtype {
            switch subtype {
            case "silhouette":
                return String(localized: "Silhouette image for question", comment: "Accessibility label for a silhouette image question")
            case "blind_map":
                return String(localized: "Map image for question", comment: "Accessibility label for a blind-map image question")
            case "hint_image":
                return String(localized: "Hint image for question", comment: "Accessibility label for a hint image question")
            default:
                return String(localized: "Image for question", comment: "Accessibility label for a generic image question")
            }
        }
        return String(localized: "Image for question", comment: "Accessibility label for a generic image question")
    }

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
                            .accessibilityLabel(String(localized: "Image failed to load", comment: "Accessibility label shown when a question image fails to load"))
                    case .empty:
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .fill(Theme.Colors.bgCard)
                            .frame(height: 200)
                            .overlay(
                                ProgressView()
                                    .tint(Theme.Colors.accentPrimary)
                            )
                            .accessibilityLabel(String(localized: "Loading image", comment: "Accessibility label shown while a question image is loading"))
                    @unknown default:
                        EmptyView()
                    }
                }
                .accessibilityLabel(imageAccessibilityLabel)
                .padding(.horizontal, Theme.Spacing.md)
            }

            // Question text (always visible — fallback for driving mode)
            Text(question.question)
                .font(.displayLG)
                .foregroundColor(Theme.Colors.textPrimary)
                .multilineTextAlignment(.center)
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
