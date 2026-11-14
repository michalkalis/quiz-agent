//
//  SharedQuizLink.swift
//  Hangs
//
//  #232: the shared quiz link, built and read.
//

import Foundation

/// The link a shared quiz travels as: `https://trubbo.app/play?s=TOKEN`.
/// Without the app it opens the trubbo.app play page, which leads to the
/// App Store; with the app it is a universal link.
nonisolated enum SharedQuizLink {
    static let pageURL = "https://trubbo.app/play"
    static let tokenQueryItem = "s"

    static func url(token: String) -> URL {
        var components = URLComponents(string: pageURL)
        components?.queryItems = [URLQueryItem(name: tokenQueryItem, value: token)]
        return components?.url ?? URL(fileURLWithPath: "/")
    }

    /// The token of a `https://trubbo.app/play?s=…` link, nil for anything
    /// else. The token's shape matches the server's (8–64 of A–Z a–z 0–9 _ -).
    static func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == "trubbo.app",
              components.path == "/play" || components.path == "/play/",
              let token = components.queryItems?.first(where: { $0.name == tokenQueryItem })?.value,
              isToken(token)
        else { return nil }
        return token
    }

    /// The token of pasted text that is exactly such a link (surrounding
    /// whitespace allowed); a message with more text around it is not one.
    static func token(fromPasted text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return nil }
        return token(from: url)
    }

    private static func isToken(_ value: String) -> Bool {
        (8 ... 64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
