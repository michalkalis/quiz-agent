//
//  VoiceCommandIndicator.swift
//  CarQuiz
//
//  Small badge showing voice command listening status
//

import SwiftUI

struct VoiceCommandIndicator: View {
    let state: VoiceCommandListeningState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xs / 2) {
            Image(systemName: iconName)
                .font(.textXS)

            Text(label)
                .font(.textXXSMedium)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs / 2)
        .background(backgroundColor)
        .cornerRadius(Theme.Radius.full)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .opacity(isPulsing && !reduceMotion ? 0.7 : 1.0)
        .animation(
            reduceMotion ? nil : (state == .listening
                ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                : .default),
            value: isPulsing
        )
        .onChange(of: state) { _, newState in
            isPulsing = newState == .listening
        }
        .onAppear {
            isPulsing = state == .listening
        }
    }

    private var iconName: String {
        switch state {
        case .disabled:
            return "mic.slash"
        case .listening:
            return "mic"
        case .commandDetected:
            return "checkmark.circle.fill"
        }
    }

    private var label: String {
        switch state {
        case .disabled:
            return "Voice Off"
        case .listening:
            return "Voice"
        case .commandDetected(let command):
            return command.rawValue.capitalized
        }
    }

    private var accessibilityDescription: String {
        switch state {
        case .disabled:
            return "Voice commands disabled"
        case .listening:
            return "Listening for voice commands"
        case .commandDetected(let command):
            return "Voice command detected: \(command.rawValue)"
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .disabled:
            return Theme.Colors.textTertiary
        case .listening:
            return Theme.Colors.accentPrimary
        case .commandDetected:
            return Theme.Colors.success
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .disabled:
            return Theme.Colors.bgCard
        case .listening:
            return Theme.Colors.accentPrimaryTint
        case .commandDetected:
            return Theme.Colors.successBg
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        VoiceCommandIndicator(state: .disabled)
        VoiceCommandIndicator(state: .listening)
        VoiceCommandIndicator(state: .commandDetected(.start))
        VoiceCommandIndicator(state: .commandDetected(.ok))
    }
    .padding()
    .background(Theme.Colors.bgPrimary)
}
