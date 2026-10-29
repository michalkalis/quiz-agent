//
//  UITestClient.swift
//  HangsUITests
//
//  Typed wrapper around the HTTP test listener bound on 127.0.0.1:9999.
//  Workaround for the iOS 26.3 simulator bug where custom URL scheme delivery
//  is silently dropped by LaunchServices (kLSApplicationNotFoundErr).
//
//  Usage:
//    let client = UITestClient()
//    try await client.sendSpokenAnswer("Paris")
//

import Foundation
import XCTest

struct UITestClient {
    private let base = URL(string: "http://127.0.0.1:9999")!

    /// The player says `text` into the open answer recording (#208.8): the
    /// app's real batch path uploads it and the mock server hears `text`.
    /// Requires `.recording`; the listener answers 404 when no recording is armed.
    func sendSpokenAnswer(_ text: String) async throws {
        try await post(path: "/stt/committed", text: text)
    }

    /// An audio interruption (phone call) hits the recording.
    func interruptRecording() async throws {
        try await post(path: "/recording/interrupt", text: nil)
    }

    /// #212: the join link of the scripted room opens on this phone.
    func openRoomLink(token: String) async throws {
        try await post(path: "/room/join", text: token)
    }

    /// #212: the scripted room's host (another phone) starts the game.
    func roomHostStarts() async throws {
        try await post(path: "/room/start", text: nil)
    }

    /// #212: the scripted room's host moves on after a reveal.
    func roomHostMovesOn() async throws {
        try await post(path: "/room/next", text: nil)
    }

    private func post(path: String, text: String?) async throws {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let text {
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        }
        guard let url = components.url else {
            XCTFail("UITestClient: could not build URL for path \(path)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 200, "UITestClient: unexpected HTTP status \(status) for \(path)")
    }

    /// POST a synthetic voice-command transcript to the in-app HTTP listener,
    /// driving the real `handleCommandTranscript` → `handleRecognizedCommand` →
    /// `routeCommand` pipeline (issue #111 T3). Lets a UI test fire e.g. "start"
    /// even though the on-device recognizer is `nil` under `--ui-test`.
    func sendCommand(_ text: String) async throws {
        var components = URLComponents(url: base.appendingPathComponent("/command/send"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "text", value: text)]
        guard let url = components.url else {
            XCTFail("UITestClient: could not build URL for command \(text)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 200, "UITestClient: unexpected HTTP status \(status) for command \(text)")
    }
}
