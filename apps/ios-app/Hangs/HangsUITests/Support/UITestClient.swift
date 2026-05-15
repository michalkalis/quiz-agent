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
//    try await client.sendSTTEvent(path: "/stt/committed", text: "Paris")
//

import Foundation
import XCTest

struct UITestClient {
    private let base = URL(string: "http://127.0.0.1:9999")!

    /// POST a synthetic STT event to the in-app HTTP listener.
    ///
    /// - Parameters:
    ///   - path: Listener path, e.g. `"/stt/committed"`, `"/stt/partial"`,
    ///           `"/stt/connected"`, `"/stt/disconnect"`.
    ///   - text: Optional query value for the `text` parameter.
    func sendSTTEvent(path: String, text: String?) async throws {
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
}
