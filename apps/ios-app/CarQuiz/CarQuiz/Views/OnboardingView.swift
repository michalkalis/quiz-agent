//
//  OnboardingView.swift
//  Hangs
//
//  First-launch onboarding explaining voice features and requesting mic permission
//

import AVFoundation
import SwiftUI

struct OnboardingView: View {
    let audioService: AudioServiceProtocol
    let onComplete: () -> Void

    @State private var currentPage = 0
    @State private var micPermissionGranted = false

    private let pageCount = 3

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $currentPage) {
                welcomePage.tag(0)
                featuresPage.tag(1)
                micPermissionPage.tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.3), value: currentPage)

            // Bottom controls
            VStack(spacing: Theme.Spacing.md) {
                // Page indicator
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        Circle()
                            .fill(index == currentPage ? Theme.Colors.accentPrimary : Theme.Colors.textMuted)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Page \(currentPage + 1) of \(pageCount)")

                // Action button
                if currentPage < pageCount - 1 {
                    PrimaryButton(title: "Continue", icon: "arrow.right") {
                        currentPage += 1
                    }
                    .accessibilityIdentifier("onboarding.continue")
                } else {
                    PrimaryButton(title: "Get Started", icon: "play.fill") {
                        onComplete()
                    }
                    .accessibilityIdentifier("onboarding.getStarted")
                }

                // Skip (not on last page)
                if currentPage < pageCount - 1 {
                    Button("Skip") {
                        onComplete()
                    }
                    .font(.textMDMedium)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .accessibilityHint("Skip onboarding and go to the app")
                    .accessibilityIdentifier("onboarding.skip")
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.Colors.bgPrimary)
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Theme.Colors.accentPrimaryTint)
                    .frame(width: 120, height: 120)

                Image(systemName: "mic.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundColor(Theme.Colors.accentPrimary)
            }
            .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Answer by Voice")
                    .font(.displayXXL)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("Hangs reads questions aloud and listens for your answers. No tapping needed during a quiz.")
                    .font(.textMD)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.lg)
            }

            Spacer()
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Page 2: Hands-Free Features

    private var featuresPage: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            VStack(spacing: Theme.Spacing.sm) {
                Text("Hands-Free Features")
                    .font(.displayXXL)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text("Perfect for driving, cooking, or walking.")
                    .font(.textMD)
                    .foregroundColor(Theme.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                FeatureRow(
                    icon: "waveform.badge.mic",
                    title: "Auto-Record",
                    description: "Recording starts automatically after each question"
                )
                FeatureRow(
                    icon: "hand.raised.fill",
                    title: "Barge-In",
                    description: "Start speaking to interrupt the question and answer immediately"
                )
                FeatureRow(
                    icon: "text.bubble",
                    title: "Voice Commands",
                    description: "Say \"skip\", \"repeat\", \"score\", or \"help\" anytime"
                )
                FeatureRow(
                    icon: "arrow.forward.circle",
                    title: "Auto-Advance",
                    description: "Results advance automatically so you never need to tap"
                )
            }
            .padding(.horizontal, Theme.Spacing.md)

            Spacer()
            Spacer()
        }
    }

    // MARK: - Page 3: Microphone Permission

    private var micPermissionPage: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(micPermissionGranted ? Theme.Colors.successBg : Theme.Colors.accentPrimaryTint)
                    .frame(width: 120, height: 120)

                Image(systemName: micPermissionGranted ? "checkmark.circle.fill" : "mic.badge.plus")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundColor(micPermissionGranted ? Theme.Colors.success : Theme.Colors.accentPrimary)
            }
            .accessibilityHidden(true)

            VStack(spacing: Theme.Spacing.sm) {
                Text(micPermissionGranted ? "You're All Set!" : "Microphone Access")
                    .font(.displayXXL)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text(micPermissionGranted
                     ? "Hangs can hear your answers. Tap \"Get Started\" to play!"
                     : "Hangs needs microphone access to hear your voice answers. You can also type answers as a fallback.")
                    .font(.textMD)
                    .foregroundColor(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.lg)
            }

            if !micPermissionGranted {
                Button {
                    Task {
                        micPermissionGranted = await audioService.requestMicrophonePermission()
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "mic.fill")
                        Text("Allow Microphone")
                    }
                    .font(.displayMD)
                    .foregroundColor(Theme.Colors.textOnAccent)
                    .padding(.vertical, Theme.Spacing.md)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .background(Theme.Gradients.primary())
                    .cornerRadius(Theme.Radius.full)
                }
                .accessibilityHint("Opens system dialog to allow microphone access")
                .accessibilityIdentifier("onboarding.allowMic")
            }

            Spacer()
            Spacer()
        }
        .onAppear {
            // Check if permission was already granted
            let status = AVAudioApplication.shared.recordPermission
            micPermissionGranted = (status == .granted)
        }
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: Theme.Components.iconMD))
                .foregroundColor(Theme.Colors.accentPrimary)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.displayMD)
                    .foregroundColor(Theme.Colors.textPrimary)

                Text(description)
                    .font(.textSM)
                    .foregroundColor(Theme.Colors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView(audioService: AudioService()) {
        print("Onboarding complete!")
    }
}
