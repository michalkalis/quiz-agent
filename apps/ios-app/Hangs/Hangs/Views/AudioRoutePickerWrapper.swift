//
//  AudioRoutePickerWrapper.swift
//  Hangs
//
//  SwiftUI wrapper for AVRoutePickerView (system audio output picker)
//

import AVKit
import SwiftUI

/// SwiftUI wrapper for AVRoutePickerView
/// Shows the system audio route picker for output device selection
struct AudioRoutePickerWrapper: UIViewRepresentable {
    /// Tint color for the picker button
    var tintColor: UIColor = .systemBlue

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tintColor

        // Match the prioritization with our audio session setup
        picker.prioritizesVideoDevices = false

        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
    }
}

/// Styled audio route picker button for HomeView settings panel
struct AudioRoutePickerButton: View {
    var body: some View {
        HStack {
            AudioRoutePickerWrapper()
                .frame(width: 24, height: 24)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        AudioRoutePickerButton()
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)

        Text("Tap the speaker icon to select audio output")
            .font(.caption)
            .foregroundColor(.secondary)
    }
    .padding()
}
