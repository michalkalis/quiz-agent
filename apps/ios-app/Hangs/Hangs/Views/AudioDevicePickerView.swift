//
//  AudioDevicePickerView.swift
//  Hangs
//
//  Custom picker sheet for selecting audio input device (microphone)
//

import SwiftUI

/// Sheet view for selecting audio input device
struct AudioDevicePickerView: View {
    private enum Metrics {
        static let iconColumn: CGFloat = 32 // fixed column so device names align
    }

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
                        HangsSectionLabel(text: "Available Devices")
                    } footer: {
                        if viewModel.selectedAudioMode.id == "media" {
                            Text("Switch to Call Mode to use Bluetooth microphones. With a Bluetooth microphone the car treats the quiz as a phone call.")
                                .font(.hangsBody(12))
                                .foregroundColor(Theme.Hangs.Colors.muted)
                        }
                    }
                }

                // No devices available message
                if viewModel.availableInputDevices.isEmpty {
                    Section {
                        HStack(spacing: Theme.Hangs.Spacing.sm) {
                            Image(systemName: "info.circle")
                                .foregroundColor(Theme.Hangs.Colors.muted)
                            Text("No external microphones detected. Connect Bluetooth or wired audio devices to see them here.")
                                .font(.hangsBody(14))
                                .foregroundColor(Theme.Hangs.Colors.muted)
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
                    .accessibilityIdentifier("micPicker.done")
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
            HStack(spacing: Theme.Hangs.Spacing.sm) {
                // Device icon
                Image(systemName: device.isAutomatic ? "wand.and.stars" : device.icon)
                    .font(.title3)
                    .foregroundColor(Theme.Hangs.Colors.muted)
                    .frame(width: Metrics.iconColumn)

                // Device name and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.hangsBody(16, weight: .semibold))
                        .foregroundColor(Theme.Hangs.Colors.ink)

                    if !device.isAutomatic {
                        Text(device.subtitle)
                            .font(.hangsBody(12))
                            .foregroundColor(Theme.Hangs.Colors.muted)
                    } else {
                        Text("Let iOS choose the best microphone")
                            .font(.hangsBody(12))
                            .foregroundColor(Theme.Hangs.Colors.muted)
                    }
                }

                Spacer()

                // Checkmark for selected device
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.Hangs.Colors.rowValue)
                        .fontWeight(.semibold)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("micPicker.device.\(device.id)")
    }
}

#if DEBUG
    #Preview {
        AudioDevicePickerView(viewModel: QuizViewModel.preview)
    }
#endif
