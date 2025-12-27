//
//  AudioMode.swift
//  CarQuiz
//
//  Audio mode configuration for Bluetooth devices
//

import Foundation

/// Bluetooth audio mode for quiz playback and recording
struct AudioMode: Identifiable, Hashable, Sendable {
    let id: String  // Mode identifier ("call" or "media")
    let name: String  // Display name (e.g., "Call Mode")
    let description: String  // User-facing explanation
    let icon: String  // SF Symbol name for UI

    /// All supported audio modes
    static let supportedModes: [AudioMode] = [
        AudioMode(
            id: "call",
            name: "Call Mode",
            description: "Uses Bluetooth microphone (may show as phone call in car)",
            icon: "phone.fill"
        ),
        AudioMode(
            id: "media",
            name: "Media Mode",
            description: "Car-friendly audio (built-in mic only, no call UI)",
            icon: "car.fill"
        )
    ]

    /// Default mode (Call Mode - preserves existing behavior)
    static let `default` = supportedModes[0]

    /// Find mode by ID
    /// - Parameter id: Mode identifier ("call" or "media")
    /// - Returns: AudioMode if found, nil otherwise
    static func forId(_ id: String) -> AudioMode? {
        supportedModes.first(where: { $0.id == id })
    }
}
