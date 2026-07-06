//
//  ImageQuestionView.swift
//  Hangs
//
//  Image block for an image-type question (#68). Rendered inside the question
//  hero above the question text — the text itself stays owned by QuestionView
//  (G1: scrollable question region, Anton display). Load failure degrades to a
//  quiet placeholder; the spoken question via TTS is the driving-mode fallback.
//

import SwiftUI

struct ImageQuestionView: View {
    let question: Question

    private var imageAccessibilityLabel: String {
        switch question.imageSubtype {
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

    var body: some View {
        if let mediaUrl = question.mediaUrl, let url = URL(string: mediaUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 280)
                        .frame(maxWidth: .infinity)
                        .cornerRadius(Theme.Hangs.Radius.card)
                case .failure:
                    // Silent placeholder — quiz continues via TTS
                    placeholder {
                        Image(systemName: "photo")
                            .font(.system(size: 40))
                            .foregroundColor(Theme.Hangs.Colors.muted.opacity(0.4))
                    }
                    .accessibilityLabel(String(localized: "Image failed to load", comment: "Accessibility label shown when a question image fails to load"))
                case .empty:
                    placeholder {
                        ProgressView()
                            .tint(Theme.Hangs.Colors.pink)
                    }
                    .accessibilityLabel(String(localized: "Loading image", comment: "Accessibility label shown while a question image is loading"))
                @unknown default:
                    EmptyView()
                }
            }
            .accessibilityLabel(imageAccessibilityLabel)
            .accessibilityIdentifier("question.image")
        }
    }

    private func placeholder(@ViewBuilder overlay: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: Theme.Hangs.Radius.card)
            .fill(Theme.Hangs.Colors.bgCard)
            .frame(height: 200)
            .frame(maxWidth: .infinity)
            .overlay(overlay())
    }
}

#if DEBUG
    #Preview {
        ImageQuestionView(question: .previewImage)
            .padding(24)
            .background(Theme.Hangs.Colors.bg)
    }
#endif
