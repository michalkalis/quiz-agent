//
//  MicrophoneHeadsetTests.swift
//  HangsTests
//
//  #200 (TF test 2026-10-12): AirPods were connected, but Settings > Microphone
//  listed only the iPhone. Media Mode (the default) asks the session for A2DP
//  only, iOS then offers no Bluetooth input, and the app could not even show
//  that headphones are connected. Why these tests matter:
//  - Connected Bluetooth headphones must be listed, or the founder (and anyone
//    with AirPods) sees nothing about them and cannot tell where answers are
//    recorded.
//  - They are information only in Media Mode. Switching to the headphones'
//    microphone would put the car on a phone call and degrade the sound (#104),
//    so listing them must never change the audio mode or the chosen input.
//  - In call mode iOS offers the real HFP input and that row stays the normal
//    selectable one, with no second entry for the same headphones.
//  - The lists change with the mode and the route, and nothing observes the
//    audio service, so those two events must re-read and republish them.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
@testable import Hangs
import Testing

// Uids as iOS names one headset's ports: shared hardware address, profile suffix.
let airPodsOutput = AudioDevice(
    id: "AA-BB-CC-DD-EE-FF-tacl",
    name: "Michal's AirPods",
    portType: AVAudioSession.Port.bluetoothA2DP.rawValue
)
let airPodsMic = AudioDevice(
    id: "AA-BB-CC-DD-EE-FF-tsco",
    name: "Michal's AirPods",
    portType: AVAudioSession.Port.bluetoothHFP.rawValue
)

/// A view model over a mock whose route has AirPods on the A2DP output and only
/// the iPhone microphone as an input, which is what Media Mode looks like.
@MainActor
func makeHeadphonesVM(audioMode: String = "media") -> (QuizViewModel, MockAudioService) {
    let audio = MockAudioService()
    audio.availableInputDevices = [.previewBuiltIn]
    audio.bluetoothOutputDevices = [airPodsOutput]
    let vm = QuizViewModel(
        networkService: MockNetworkService(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: MockSilenceDetectionService()
    )
    vm.settings.audioMode = audioMode
    return (vm, audio)
}

@Suite("Bluetooth headphones in the microphone list (#200)")
@MainActor
struct MicrophoneHeadsetTests {
    @Test("AirPods on the A2DP output with no Bluetooth input are listed next to the iPhone microphone")
    func headphonesOnOutputRouteAreListed() {
        let (vm, _) = makeHeadphonesVM()

        let devices = vm.availableInputDevices
        #expect(devices.map(\.name) == ["iPhone Microphone", "Michal's AirPods"])
        #expect(devices[1].isOutputOnly, "iOS offers no microphone for them, so the row is information and not an input")
        #expect(devices[1].id == airPodsOutput.id)
    }

    @Test("headphones whose Bluetooth input iOS offers (call mode) are one normal row, not two")
    func headphonesWithInputAreNotDoubled() {
        let (vm, audio) = makeHeadphonesVM(audioMode: "call")
        audio.availableInputDevices = [.previewBuiltIn, airPodsMic]

        let devices = vm.availableInputDevices
        #expect(devices == [.previewBuiltIn, airPodsMic])
        #expect(devices.allSatisfy { !$0.isOutputOnly }, "in call mode the row is the real, selectable input")
    }

    @Test("another Bluetooth device on the output stays listed when the AirPods have their input")
    func otherBluetoothDeviceStaysListed() {
        let carOutput = AudioDevice(
            id: "11-22-33-44-55-66-tacl",
            name: "Skoda Infotainment",
            portType: AVAudioSession.Port.bluetoothA2DP.rawValue
        )
        let (vm, audio) = makeHeadphonesVM(audioMode: "call")
        audio.availableInputDevices = [.previewBuiltIn, airPodsMic]
        audio.bluetoothOutputDevices = [airPodsOutput, carOutput]

        let devices = vm.availableInputDevices
        #expect(devices.map(\.name) == ["iPhone Microphone", "Michal's AirPods", "Skoda Infotainment"])
        #expect(devices.filter(\.isOutputOnly).map(\.id) == [carOutput.id])
    }

    @Test("the input and output ports of one headset match by uid stem, then by name")
    func portsOfOneHeadsetMatch() {
        let renumbered = AudioDevice(id: "other-uid", name: "Michal's AirPods", portType: AVAudioSession.Port.bluetoothHFP.rawValue)
        #expect(airPodsOutput.isSameBluetoothDevice(as: airPodsMic))
        #expect(airPodsOutput.isSameBluetoothDevice(as: renumbered), "a stack that numbers ports differently still has one name")
        #expect(!airPodsOutput.isSameBluetoothDevice(as: .previewBuiltIn), "the iPhone microphone is never a headset's input")
    }

    @Test("listing headphones changes neither the audio mode nor the chosen microphone")
    func listingIsInformationOnly() {
        let (vm, audio) = makeHeadphonesVM()

        _ = vm.availableInputDevices

        #expect(vm.settings.audioMode == "media", "Media Mode is what keeps the car off a phone call (#104)")
        #expect(vm.settings.preferredInputDeviceId == nil)
        #expect(audio.currentInputDevice == nil)
    }

    @Test("toggling call mode re-reads the device lists")
    func modeToggleRefreshesDevices() async {
        let (vm, audio) = makeHeadphonesVM()
        let before = audio.refreshAvailableDevicesCallCount

        vm.toggleAudioMode()
        await pumpUntil({ vm.settings.audioMode == "call" }, "mode never flipped to call")

        #expect(audio.refreshAvailableDevicesCallCount > before, "which inputs iOS offers depends on the mode, a stale list hides the headphones' microphone")
    }

    @Test("a route change republishes the lists so an open picker shows headphones connecting")
    func routeChangeRepublishes() async {
        let (vm, _) = makeHeadphonesVM()
        var published = 0
        let subscription = vm.audioDeviceState.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        await vm.audioDeviceState.handleAudioRouteChange(
            AudioRouteChange(
                reason: .newDeviceAvailable,
                outputPort: "BluetoothA2DPOutput",
                previousOutputPort: "Speaker",
                voiceProcessingMode: .offOutput
            )
        )

        #expect(published > 0)
    }
}
