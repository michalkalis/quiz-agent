//
//  SharedQuizMessage.swift
//  Hangs
//
//  #232: the message a shared quiz is sent with (founder 2026-11-14, text B).
//  The link is always the last line, so a chat app makes its preview from it:
//
//      Zahraj si môj kvíz v Trubbe. Je to 10 otázok, mám 7. Koľko dáš ty?
//      https://trubbo.app/play?s=K7m2Qx
//

import Foundation

nonisolated enum SharedQuizMessage {
    /// A round (or a pack round): how many questions and the sender's score.
    static func round(questionCount: Int, score: String, url: URL) -> String {
        let text = String(localized: "Play my quiz in Trubbo. It's \(questionCount) questions and I got \(score). How many will you get?", bundle: .interface, locale: .interface, comment: "#232 share message (text B): question count, then the sender's score. The link follows on its own line")
        return text + "\n" + url.absoluteString
    }

    /// A whole custom pack, sent without having a score for it.
    static func pack(questionCount: Int, url: URL) -> String {
        let text = String(localized: "Play my quiz in Trubbo. It's \(questionCount) questions. How many will you get?", bundle: .interface, locale: .interface, comment: "#232 share message for a custom pack: its question count. The link follows on its own line")
        return text + "\n" + url.absoluteString
    }

    /// The daily challenge's invite line (daily text B), above its link.
    static func dailyInvite(questionCount: Int) -> String {
        String(localized: "Play the same \(questionCount) questions", bundle: .interface, locale: .interface, comment: "#232 daily challenge share text: the line above the link to the same questions")
    }

    /// The share sheet's preview title: the quiz's topic when it has one.
    static func previewTitle(topic: String?) -> String {
        guard let topic, !topic.isEmpty else {
            return String(localized: "A quiz in Trubbo", bundle: .interface, locale: .interface, comment: "#232: share sheet preview title of a shared quiz without a topic")
        }
        return "\(topic) · Trubbo"
    }
}
