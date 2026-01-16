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
                    } footer: {
                        if viewModel.selectedAudioMode.id == "media" && viewModel.availableInputDevices.contains(where: { $0.isHFP }) {
                            Text("Switch to Call Mode in settings to use Bluetooth microphones.")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // No devices available message
                if viewModel.availableInputDevices.isEmpty {
                    Section {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.secondary)
                            Text("No external microphones detected. Connect Bluetooth or wired audio devices to see them here.")
                                .foregroundColor(.secondary)
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
            HStack(spacing: 12) {
                // Device icon
                Image(systemName: device.isAutomatic ? "wand.and.stars" : device.icon)
                    .font(.title3)
                    .foregroundColor(device.isAutomatic ? .purple : .blue)
                    .frame(width: 32)

                // Device name and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .foregroundColor(.primary)

                    if !device.isAutomatic {
                        Text(device.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Let iOS choose the best microphone")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Checkmark for selected device
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
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
