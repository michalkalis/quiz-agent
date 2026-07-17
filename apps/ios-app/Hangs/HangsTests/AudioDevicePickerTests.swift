//
//  AudioDevicePickerTests.swift
//  HangsTests
//
//  #104 follow-up — Media Mode no longer requests Bluetooth HFP, so Bluetooth
//  microphones no longer appear in availableInputDevices while in Media Mode.
//  The mic-picker footer hint used to require an HFP device to be present to
//  show, which after the change can never fire in exactly the situation it's
//  meant for. These tests pin the corrected behavior:
//  - the footer shows whenever the user is in Media Mode (regardless of what
//    devices happen to be listed), so it's actually reachable.
//  - setPreferredInputDevice's persistence contract (settings.preferredInputDeviceId)
//    stays correct, since the footer's advice depends on device selection working.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite("AudioDevicePickerView — Media Mode Bluetooth hint (#104 follow-up)")
struct AudioDevicePickerTests {
    @Test("in media mode, the picker renders the 'Switch to Call Mode' footer hint")
    func mediaModeShowsFooterHint() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()
        viewModel.settings.audioMode = "media"

        let view = AudioDevicePickerView(viewModel: viewModel)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) {
                try tree.find(text: "Switch to Call Mode to use Bluetooth microphones. With a Bluetooth microphone the car treats the quiz as a phone call.")
            }
        }
    }

    @Test("setPreferredInputDevice sets and clears settings.preferredInputDeviceId")
    func setPreferredInputDevicePersistsAndClears() async throws {
        let viewModel = Fixtures.makeViewModelForTimerTests()

        viewModel.setPreferredInputDevice(.previewBluetooth)
        #expect(viewModel.settings.preferredInputDeviceId == AudioDevice.previewBluetooth.id)

        viewModel.setPreferredInputDevice(nil)
        #expect(viewModel.settings.preferredInputDeviceId == nil)
    }
}
