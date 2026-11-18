//
//  AudioDevice.swift
//  Hangs
//
//  Model representing audio input/output devices
//

import AVFoundation
import Foundation

/// Represents an audio device (microphone or speaker)
/// Maps to AVAudioSessionPortDescription for input devices
struct AudioDevice: Identifiable, Codable, Sendable, Hashable {
    /// Unique identifier from AVAudioSessionPortDescription.uid
    let id: String

    /// Human-readable device name
    let name: String

    /// Port type string (e.g., "builtInMic", "bluetoothHFP")
    let portType: String

    /// #200: a Bluetooth device iOS reports on the OUTPUT route only. Media Mode
    /// asks the session for A2DP (output) and iOS then offers no Bluetooth
    /// microphone, so the headphones are connected and playing the quiz yet
    /// absent from `availableInputs`. The picker lists them for information; they
    /// are not an input. `id` is the output port's uid, never persisted.
    var isOutputOnly = false

    private enum CodingKeys: String, CodingKey {
        case id, name, portType
    }

    /// Whether this is a built-in device (mic/speaker)
    var isBuiltIn: Bool {
        portType == AVAudioSession.Port.builtInMic.rawValue ||
        portType == AVAudioSession.Port.builtInSpeaker.rawValue ||
        portType == AVAudioSession.Port.builtInReceiver.rawValue
    }

    /// Whether this is a Bluetooth device (HFP or A2DP)
    var isBluetooth: Bool {
        portType == AVAudioSession.Port.bluetoothHFP.rawValue ||
        portType == AVAudioSession.Port.bluetoothA2DP.rawValue ||
        portType == AVAudioSession.Port.bluetoothLE.rawValue
    }

    /// Whether this is a Hands-Free Profile device (mic-capable Bluetooth)
    var isHFP: Bool {
        portType == AVAudioSession.Port.bluetoothHFP.rawValue
    }

    /// SF Symbol icon for this device type
    var icon: String {
        if isBuiltIn {
            return "iphone"
        } else if isHFP {
            return "car.fill"
        } else if isBluetooth {
            return "airpodspro"
        } else if portType == AVAudioSession.Port.headphones.rawValue {
            return "headphones"
        } else if portType == AVAudioSession.Port.usbAudio.rawValue {
            return "cable.connector"
        } else {
            return "speaker.wave.2"
        }
    }

    /// Display subtitle describing the device type
    var subtitle: String {
        if isOutputOnly {
            return String(localized: "Bluetooth, plays the quiz sound", bundle: .interface, locale: .interface, comment: "Microphone picker row note for connected Bluetooth headphones (information only, not selectable as a microphone)")
        } else if isBuiltIn {
            return String(localized: "Built-in", bundle: .interface, locale: .interface, comment: "Audio device subtitle: the device's built-in microphone")
        } else if isHFP {
            return String(localized: "Bluetooth (Call Mode)", bundle: .interface, locale: .interface, comment: "Audio device subtitle: a Bluetooth mic in hands-free call mode")
        } else if isBluetooth {
            return String(localized: "Bluetooth", bundle: .interface, locale: .interface, comment: "Audio device subtitle: a Bluetooth audio device")
        } else if portType == AVAudioSession.Port.headphones.rawValue {
            return String(localized: "Wired", bundle: .interface, locale: .interface, comment: "Audio device subtitle: a wired headset/headphones")
        } else if portType == AVAudioSession.Port.usbAudio.rawValue {
            return String(localized: "USB", bundle: .interface, locale: .interface, comment: "Audio device subtitle: a USB audio device")
        } else {
            return String(localized: "External", bundle: .interface, locale: .interface, comment: "Audio device subtitle: a generic external audio device")
        }
    }

    /// Whether `other` is the same physical Bluetooth device on another profile.
    /// One headset exposes an output (A2DP / LE) and an input (HFP) port with
    /// different uids that share the hardware-address stem before the profile
    /// suffix ("AA-BB-CC-DD-EE-FF-tacl" vs "...-tsco"); the name is the fallback
    /// for stacks that number the ports differently.
    func isSameBluetoothDevice(as other: AudioDevice) -> Bool {
        guard isBluetooth, other.isBluetooth else { return false }
        func stem(_ uid: String) -> String {
            uid.lastIndex(of: "-").map { String(uid[..<$0]) } ?? uid
        }
        let ownStem = stem(id)
        if !ownStem.isEmpty, ownStem.caseInsensitiveCompare(stem(other.id)) == .orderedSame { return true }
        let ownName = name.trimmingCharacters(in: .whitespaces)
        return !ownName.isEmpty && ownName.caseInsensitiveCompare(other.name.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// The microphone list: the inputs iOS offers plus, for each Bluetooth
    /// device on the output route that has no input of its own among them, an
    /// `isOutputOnly` entry. Pure so the rule is testable without a session.
    static func pickerList(inputs: [AudioDevice], bluetoothOutputs: [AudioDevice]) -> [AudioDevice] {
        var list = inputs
        for output in bluetoothOutputs where !list.contains(where: { $0.isSameBluetoothDevice(as: output) }) {
            var entry = output
            entry.isOutputOnly = true
            list.append(entry)
        }
        return list
    }

    // MARK: - Factory Methods

    /// Create from AVAudioSessionPortDescription
    /// - Parameter port: The port description from AVAudioSession
    /// - Returns: AudioDevice representing the port
    static func from(port: AVAudioSessionPortDescription) -> AudioDevice {
        AudioDevice(
            id: port.uid,
            name: port.portName,
            portType: port.portType.rawValue
        )
    }

    // MARK: - Special Devices

    /// "Automatic" device - lets iOS choose the best available input
    static var automatic: AudioDevice {
        AudioDevice(
            id: "automatic",
            name: String(localized: "Automatic", bundle: .interface, locale: .interface, comment: "Name of the automatic audio input device (iOS picks the best mic)"),
            portType: "automatic"
        )
    }

    /// Check if this is the automatic device
    var isAutomatic: Bool {
        id == "automatic"
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension AudioDevice {
    static let previewBuiltIn = AudioDevice(
        id: "Built-In-Mic",
        name: "iPhone Microphone",
        portType: AVAudioSession.Port.builtInMic.rawValue
    )

    static let previewBluetooth = AudioDevice(
        id: "CarPlay-HFP",
        name: "Car Audio System",
        portType: AVAudioSession.Port.bluetoothHFP.rawValue
    )

    static let previewAirPods = AudioDevice(
        id: "AirPods-Pro",
        name: "AirPods Pro",
        portType: AVAudioSession.Port.bluetoothHFP.rawValue
    )
}
#endif
