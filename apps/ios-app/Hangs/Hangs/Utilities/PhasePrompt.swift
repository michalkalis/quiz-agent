//
//  PhasePrompt.swift
//  Hangs
//
//  #243.3 (founder 2026-11-24, decision 1): the quiz says which phase starts,
//  in one short line in the app voice, plus the quiet mic tone it already had.
//  The first two questions of a quiz get the longer think line with the
//  seconds ("Premýšľaj, máš desať sekúnd."), the rest only "Premýšľaj." and
//  "Odpovedaj.".
//
//  The lines are ElevenLabs clips in the app voice, generated once by
//  `scripts/generate_phase_prompts.py` and bundled under
//  `Resources/PhasePrompts`, so they play at once and without signal. Never
//  the iOS system voice (founder 2026-11-24). The texts live in that script.
//

import Foundation

enum PhasePrompt: Equatable, Sendable {
    /// The think window starts. `seconds` names the window in the longer
    /// line; `nil`, or a length without its own clip, says just "Think.".
    case think(seconds: Int?)
    /// Back to thinking after an answer window heard nothing (#243.4).
    case thinkMore
    /// The mic opens on its own for the answer.
    case answer
    /// The second silence (#243.4): "I can't hear an answer. Say: repeat, and
    /// I'll read the question. Say: again, …" — the long line the first
    /// `longNoAnswerOfferPlays` times a player hears it, then `noAnswerOfferShort`.
    case noAnswerOffer
    /// "I can't hear an answer. Say: repeat. Again. Or next." (#243.4).
    case noAnswerOfferShort

    /// How many times the long offer plays before the short one (founder
    /// 2026-11-24), counted across quizzes.
    static let longNoAnswerOfferPlays = 2

    /// The offer for a player who has heard it `heardCount` times before.
    static func noAnswerOffer(heardCount: Int) -> PhasePrompt {
        heardCount < longNoAnswerOfferPlays ? .noAnswerOffer : .noAnswerOfferShort
    }

    /// Think windows with a longer clip, the think-time presets (#243.8).
    static let spokenThinkSeconds: Set<Int> = [5, 10, 20, 30]

    /// The bundled file's name without language and extension.
    var resourceName: String {
        switch self {
        case let .think(seconds?) where Self.spokenThinkSeconds.contains(seconds): "think-\(seconds)"
        case .think: "think"
        case .thinkMore: "think-more"
        case .answer: "answer"
        case .noAnswerOffer: "no-answer-offer"
        case .noAnswerOfferShort: "no-answer-offer-short"
        }
    }

    /// The clip in `language`, or nil when the bundle lacks it (the phase
    /// then starts without a line rather than waiting on a network voice).
    func audio(language: CommandLanguage, bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: "\(resourceName).\(language.rawValue)", withExtension: "mp3") else {
            return nil
        }
        // A file the bundle lists but cannot read is a build defect
        // (`PhasePromptTests` reads every one); the phase then starts silent.
        return try? Data(contentsOf: url)
    }
}
