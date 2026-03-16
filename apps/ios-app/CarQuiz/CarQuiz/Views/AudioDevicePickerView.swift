//
//  AudioDevicePickerView.swift
//  CarQuiz
//
//  Custom picker sheet for selecting audio input device (microphone)
//

import SwiftUI

/// Sheet view for selecting audio input device
struct AudioDevicePickerView: View {
    @ObservedObject var viewModel: QuizViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Automatic option
                deviceRow(device: .automatic, isSelected: viewModel.selectedInputDevice == nil)

                // Available devices section
                if !viewModel.availableInputDevices.isEmpty {
                    Section {
                        ForEach(viewModel.availableInputDevices) { device in
                            deviceRow(
                                device: device,
                                isSelected: viewModel.selectedInputDevice?.id == device.id
                            )
                        }
                    } header: {
                        Text("Available Devices")
                            .font(.labelSM)
                            .foregroundColor(Theme.Colors.textSecondary)
                    } footer: {
                        if viewModel.selectedAudioMode.id == "media" && viewModel.availableInputDevices.contains(where: { $0.isHFP }) {
                            Text("Switch to Call Mode in settings to use Bluetooth microphones.")
                                .font(.textXS)
                                .foregroundColor(Theme.Colors.textSecondary)
                        }
                    }
                }

                // No devices available message
                if viewModel.availableInputDevices.isEmpty {
                    Section {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "info.circle")
                                .foregroundColor(Theme.Colors.textSecondary)
                            Text("No external microphones detected. Connect Bluetooth or wired audio devices to see them here.")
                                .font(.textSM)
                                .foregroundColor(Theme.Colors.textSecondary)
                        }
                    }
                }
            }
            .navigationTitle("Microphone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .foregroundColor(Theme.Colors.accentPrimary)
                }
            }
            .onAppear {
                viewModel.refreshAudioDevices()
            }
        }
    }

    @ViewBuilder
    private func deviceRow(device: AudioDevice, isSelected: Bool) -> some View {
        Button(action: {
            if device.isAutomatic {
                viewModel.setPreferredInputDevice(nil)
            } else {
                viewModel.setPreferredInputDevice(device)
            }
        }) {
            HStack(spacing: Theme.Spacing.sm) {
                // Device icon
                Image(systemName: device.isAutomatic ? "wand.and.stars" : device.icon)
                    .font(.textLG)
                    .foregroundColor(device.isAutomatic ? Theme.Colors.accentPrimary : Theme.Colors.accentPrimary)
                    .frame(width: Theme.Components.iconLG)

                // Device name and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.textMD)
                        .foregroundColor(Theme.Colors.textPrimary)

                    if !device.isAutomatic {
                        Text(device.subtitle)
                            .font(.textXS)
                            .foregroundColor(Theme.Colors.textSecondary)
                    } else {
                        Text("Let iOS choose the best microphone")
                            .font(.textXS)
                            .foregroundColor(Theme.Colors.textSecondary)
                    }
                }

                Spacer()

                // Checkmark for selected device
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.Colors.accentPrimary)
                        .fontWeight(.semibold)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview {
    AudioDevicePickerView(viewModel: QuizViewModel.preview)
}
