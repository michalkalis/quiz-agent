import Foundation
@testable import Hangs
import Testing

/// The servers count text length in Unicode scalars (Python `len`). The app
/// must cut pastes the same way, or an emoji-heavy name or answer that looks
/// within the limit on the phone is refused after Send.
@Suite("Text input limits match the server")
struct TextInputLimitTests {
    @Test("Short text is untouched")
    func shortTextUntouched() {
        #expect("Hrady 🏰".prefix(scalars: 24) == "Hrady 🏰")
    }

    @Test("A cut never exceeds the scalar budget nor splits an emoji")
    func cutsOnWholeCharacters() {
        // 👨‍👩‍👧 is one character but five scalars.
        let family = "👨\u{200D}👩\u{200D}👧"
        let cut = ("abc" + family).prefix(scalars: 6)
        #expect(cut == "abc", "the family emoji does not fit whole, so it is dropped, not broken")
        #expect(("abc" + family).prefix(scalars: 8) == "abc" + family)
    }

    @Test("A player name with emoji stays within the server's 24")
    func nameWithEmoji() {
        let name = PlayerNameStore.cleaned(String(repeating: "👨\u{200D}👩\u{200D}👧", count: 6))
        #expect((name?.unicodeScalars.count ?? 0) <= PlayerNameStore.maxLength)
        #expect(name?.isEmpty == false)
    }
}
