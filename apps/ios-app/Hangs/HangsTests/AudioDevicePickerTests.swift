//
//  AudioDevicePickerTests.swift
//  HangsTests
//
//  #104 follow-up — Media Mode no longer requests Bluetooth HFP, so Bluetooth
//  microphones no longer appear in availableInputDevices while in Media Mode.
//  #200 then made the picker list connected Bluetooth headphones anyway (from
//  the output route) as information. These tests pin:
//  - the headphones row cannot be tapped (a tap would put the car on a call),
//    and the footer says in plain words where answers are recorded and what the
//    headphones' own microphone costs, only while that applies (Media Mode with
//    Bluetooth listed).
//  - setPreferredInputDevice's persistence contract (settings.preferredInputDeviceId)
//    stays correct, since choosing a microphone depends on it.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
@Suite("AudioDevicePickerView — Bluetooth hint (#104 follow-up, #200)")
struct AudioDevicePickerTests {
    @Test("Bluetooth headphones are a row without a button, with their note and the plain-words footer")
    func headphonesRowIsInformation() async throws {
        let (viewModel, _) = makeHeadphonesVM()

        let view = AudioDevicePickerView(viewModel: viewModel)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let row = try tree.find(viewWithAccessibilityIdentifier: "micPicker.device.\(airPodsOutput.id)")
            #expect(throws: (any Error).self, "tapping headphones must not switch the mic or the mode") { try row.button() }
            #expect(throws: Never.self) { try row.find(text: "Michal's AirPods") }
            #expect(throws: Never.self) { try row.find(text: "Bluetooth, plays the quiz sound") }
            #expect(throws: Never.self) {
                try tree.find(text: "Answers are recorded by the iPhone microphone. The headphones' own microphone works only in Call Mode (in Settings). That lowers sound quality, and the car may show the quiz as a phone call.")
            }
            // The iPhone microphone stays a normal choice.
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "micPicker.device.\(AudioDevice.previewBuiltIn.id)").button()
            }
        }
    }

    @Test("without Bluetooth there is no footer to read")
    func noBluetoothNoFooter() async throws {
        let (viewModel, audio) = makeHeadphonesVM()
        audio.bluetoothOutputDevices = []

        let view = AudioDevicePickerView(viewModel: viewModel)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: (any Error).self) {
                try tree.find(textWhere: { text, _ in text.hasPrefix("Answers are recorded by the iPhone microphone.") })
            }
        }
    }

    @Test("in call mode the Bluetooth input stays a selectable row and the footer is gone")
    func callModeKeepsSelectableInput() async throws {
        let (viewModel, audio) = makeHeadphonesVM(audioMode: "call")
        audio.availableInputDevices = [.previewBuiltIn, airPodsMic]

        let view = AudioDevicePickerView(viewModel: viewModel)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let row = try tree.find(viewWithAccessibilityIdentifier: "micPicker.device.\(airPodsMic.id)")
            #expect(throws: Never.self) { try row.button() }
            #expect(throws: (any Error).self) {
                try tree.find(textWhere: { text, _ in text.hasPrefix("Answers are recorded by the iPhone microphone.") })
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
