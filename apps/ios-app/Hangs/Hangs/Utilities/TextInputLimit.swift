import SwiftUI

/// The servers' length ceilings for free text the player types or pastes.
/// Mirrored here so a long paste is cut to what the server takes instead of
/// failing only after Send. Counted in Unicode scalars, as the server counts.
enum TextInputLimit {
    /// quiz-agent `SubmitInputRequest.input`.
    static let answer = 1000
    /// quiz-agent `MESSAGE_MAX_CHARS`.
    static let feedback = 5000
    /// quiz-pack-api `REASON_MAX_CHARS`.
    static let ratingReason = 2000
}

extension String {
    /// The leading whole characters that fit in `limit` Unicode scalars. An
    /// emoji is several scalars, so a character-count prefix can overshoot.
    func prefix(scalars limit: Int) -> String {
        guard unicodeScalars.count > limit else { return self }
        var used = 0
        var end = startIndex
        for character in self {
            used += character.unicodeScalars.count
            if used > limit { break }
            end = index(after: end)
        }
        return String(self[..<end])
    }
}

extension View {
    /// Keeps `text` within `limit` scalars; the tail of a longer paste is dropped.
    func limitLength(_ text: Binding<String>, to limit: Int) -> some View {
        onChange(of: text.wrappedValue) { _, new in
            let capped = new.prefix(scalars: limit)
            if capped != new { text.wrappedValue = capped }
        }
    }
}
