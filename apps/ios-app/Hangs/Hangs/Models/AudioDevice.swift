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
        if isBuiltIn {
            return String(localized: "Built-in", comment: "Audio device subtitle: the device's built-in microphone")
        } else if isHFP {
            return String(localized: "Bluetooth (Call Mode)", comment: "Audio device subtitle: a Bluetooth mic in hands-free call mode")
        } else if isBluetooth {
            return String(localized: "Bluetooth", comment: "Audio device subtitle: a Bluetooth audio device")
        } else if portType == AVAudioSession.Port.headphones.rawValue {
            return String(localized: "Wired", comment: "Audio device subtitle: a wired headset/headphones")
        } else if portType == AVAudioSession.Port.usbAudio.rawValue {
            return String(localized: "USB", comment: "Audio device subtitle: a USB audio device")
        } else {
            return String(localized: "External", comment: "Audio device subtitle: a generic external audio device")
        }
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
    static let automatic = AudioDevice(
        id: "automatic",
        name: String(localized: "Automatic", comment: "Name of the automatic audio input device (iOS picks the best mic)"),
        portType: "automatic"
    )

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
