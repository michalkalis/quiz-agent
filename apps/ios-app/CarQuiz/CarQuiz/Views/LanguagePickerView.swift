//
//  LanguagePickerView.swift
//  CarQuiz
//
//  Language selection sheet for quiz configuration
//

import SwiftUI

struct LanguagePickerView: View {
    @Binding var selectedLanguage: Language
    let onConfirm: () -> Void

    var body: some View {
        NavigationView {
            List(Language.supportedLanguages) { language in
                Button(action: {
                    selectedLanguage = language
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(language.nativeName)
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(language.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if selectedLanguage.id == language.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Select Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        onConfirm()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    LanguagePickerView(
        selectedLanguage: .constant(Language.default),
        onConfirm: {}
    )
}
#endif
