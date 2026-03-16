//
//  MicButton.swift
//  CarQuiz
//
//  Large microphone button with gradient fill and glow effects matching Pencil design
//

import SwiftUI

/// Large microphone button with recording state and pulsing animation
struct MicButton: View {
    enum State {
        case idle
        case recording
        case processing
    }

    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background circle with gradient
                Circle()
                    .fill(backgroundGradient)
                    .frame(width: Theme.Components.micButtonLarge, height: Theme.Components.micButtonLarge)
                    .shadow(
                        color: primaryShadowColor,
                        radius: Theme.Shadows.micGlowRadius,
                        x: 0,
                        y: Theme.Shadows.micGlowY
                    )
                    .shadow(
                        color: secondaryShadowColor,
                        radius: 8,
                        x: 0,
                        y: 0
                    )
                    .accessibilityHidden(true)

                // Inner glow circle
                Circle()
                    .fill(Color.white.opacity(0.125))
                    .frame(
                        width: Theme.Components.micGlowInner,
                        height: Theme.Components.micGlowInner
                    )
                    .accessibilityHidden(true)

                // Icon
                Image(systemName: iconName)
                    .font(.system(size: Theme.Components.micIconLarge, weight: .medium))
                    .foregroundColor(.white)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(micLabel)
        .accessibilityHint(micHint)
        .disabled(state == .processing)
        .modifier(PulsingMicAnimation(isActive: state == .recording))
    }

    // MARK: - Accessibility

    private var micLabel: String {
        switch state {
        case .idle: return "Start recording answer"
        case .recording: return "Stop recording"
        case .processing: return "Processing answer"
        }
    }

    private var micHint: String {
        switch state {
        case .idle: return "Tap to record your answer"
        case .recording: return "Tap to stop recording"
        case .processing: return ""
        }
    }

    // MARK: - Computed Properties

    private var backgroundGradient: LinearGradient {
        switch state {
        case .idle:
            return Theme.Gradients.primaryAlt()
        case .recording:
            return Theme.Gradients.recording()
        case .processing:
            return LinearGradient(
                colors: [Theme.Colors.textTertiary, Theme.Colors.textTertiary],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var primaryShadowColor: Color {
        switch state {
        case .idle:
            return Color(hex: "#8B5CF6").opacity(0.31) // 50/255
        case .recording:
            return Color(hex: "#EF4444").opacity(0.4)
        case .processing:
            return .clear
        }
    }

    private var secondaryShadowColor: Color {
        switch state {
        case .idle:
            return Color(hex: "#8B5CF6").opacity(0.125) // 20/255
        case .recording:
            return Color(hex: "#EF4444").opacity(0.2)
        case .processing:
            return .clear
        }
    }

    private var iconName: String {
        switch state {
        case .idle:
            return "mic.fill"
        case .recording:
            return "stop.circle.fill"
        case .processing:
            return "waveform"
        }
    }
}

// MARK: - Pulsing Animation

private struct PulsingMicAnimation: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive && isPulsing && !reduceMotion ? 1.05 : 1.0)
            .animation(
                reduceMotion ? nil : (isActive
                    ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                    : .default),
                value: isPulsing
            )
            .onChange(of: isActive) { _, newValue in
                isPulsing = newValue
            }
            .onAppear {
                if isActive {
                    isPulsing = true
                }
            }
    }
}

#Preview {
    VStack(spacing: 40) {
        MicButton(state: .idle) {}
        MicButton(state: .recording) {}
        MicButton(state: .processing) {}
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
