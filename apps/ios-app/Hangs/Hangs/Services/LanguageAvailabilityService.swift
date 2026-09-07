//
//  LanguageAvailabilityService.swift
//  Hangs
//
//  #168 — batch translation pipeline SK/CS (DD14/DD15): which languages the
//  app may currently OFFER. `Language.supportedLanguages` stays the full ten-code
//  display catalogue (names + native names); this decides which of them the
//  three pickers actually list.
//
//  The list is server-owned (`GET /api/v1/languages` on the pack-api host) so
//  bringing a language back once its translated corpus is approved is an env
//  flip on a running deploy, not a code change and a TestFlight build. Fetched
//  once at launch, cached in UserDefaults so a cold offline launch still shows
//  the last known menu, and falling back to the compiled `en,sk,cs` when there
//  is neither.
//

import Foundation
import os

// MARK: - Wire model

/// `GET /api/v1/languages` → `{"quiz": [...], "pack_order": [...]}`.
/// Mirrors `LanguagesResponse` in `apps/quiz-pack-api/app/api/v1/languages.py`.
/// Two lists because they differ: quiz sessions serve any language with an
/// approved corpus, while custom packs are still generated in English (DD15).
nonisolated struct ServableLanguages: Codable, Sendable, Equatable {
    let quiz: [String]
    let packOrder: [String]

    enum CodingKeys: String, CodingKey {
        case quiz
        case packOrder = "pack_order"
    }
}

// MARK: - Store

/// Cache + accessor for the servable language lists.
///
/// `nonisolated` + `@unchecked Sendable`: it holds nothing but a `UserDefaults`
/// handle, which is documented thread-safe but not annotated `Sendable`, so the
/// pickers (MainActor) and the launch fetch can both reach it without hopping
/// isolation. No mutable state of its own — nothing left to protect.
nonisolated final class LanguageAvailability: @unchecked Sendable {
    /// The process-wide instance the pickers read.
    static let shared = LanguageAvailability()

    /// Compiled fallback — the servable set as of #168, used until the first
    /// successful fetch lands (fresh install, offline first launch).
    static let fallbackQuizCodes = ["en", "sk", "cs"]
    static let fallbackPackOrderCodes = ["en"]

    private static let quizKey = "servableQuizLanguages"
    private static let packOrderKey = "servablePackOrderLanguages"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Codes the quiz picker may offer (Home + Settings).
    var quizCodes: [String] {
        cached(Self.quizKey) ?? Self.fallbackQuizCodes
    }

    /// Codes the custom-pack order form may offer.
    var packOrderCodes: [String] {
        cached(Self.packOrderKey) ?? Self.fallbackPackOrderCodes
    }

    private func cached(_ key: String) -> [String]? {
        guard let stored = defaults.stringArray(forKey: key), !stored.isEmpty else { return nil }
        return stored
    }

    /// Persist a fetched response. An empty list is ignored rather than stored:
    /// a picker with no options is worse than a stale one.
    func store(_ languages: ServableLanguages) {
        if !languages.quiz.isEmpty {
            defaults.set(languages.quiz, forKey: Self.quizKey)
        }
        if !languages.packOrder.isEmpty {
            defaults.set(languages.packOrder, forKey: Self.packOrderKey)
        }
    }

    /// Fetch the current lists and cache them. Best-effort by design — a
    /// failure (offline, cold machine) leaves the cached/compiled lists in
    /// place, so the pickers always have something to show.
    func refresh(
        session: URLSession = .shared,
        baseURL: String = Config.packApiBaseURL
    ) async {
        guard let url = URL(string: baseURL + "/api/v1/languages") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            store(try JSONDecoder().decode(ServableLanguages.self, from: data))
        } catch {
            Logger.quiz.info("languages fetch skipped: \(error.localizedDescription, privacy: .public)")
        }
    }
}
