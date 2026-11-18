//
//  SharedQuizShareModel.swift
//  Hangs
//
//  #232: one quiz's link and comparison. The sender's side creates the link
//  on the first tap (never before: the server records a share only on
//  request) and hands it to the share sheet; the friend's side starts with
//  the token it played. Both then read the comparison, which the server
//  filters for the viewer.
//

import Combine
import Foundation
import os

@MainActor
final class SharedQuizShareModel: ObservableObject {
    /// What the link is made from.
    enum Source: Equatable {
        /// The caller's finished round, daily challenge or pack round.
        case session(String)
        /// The caller's finished custom pack.
        case pack(String)
    }

    enum Status: Equatable {
        case idle
        case creating
        case failed(String)
    }

    /// One line of the comparison, best first, as the screen shows it.
    struct Row: Identifiable, Equatable {
        let id: Int
        let rank: Int
        let name: String
        let isYou: Bool
        let score: String
        let marks: [Bool?]?
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var token: String?
    @Published private(set) var rows: [Row] = []
    /// The comparison could not be read (the link is gone or not this player's).
    @Published private(set) var loadFailed = false
    /// The server answered at least once, so empty `rows` means nobody has
    /// finished it yet, not "still loading" (#240 audit finding 7).
    @Published private(set) var hasLoaded = false

    private let network: NetworkServiceProtocol
    private let source: Source?
    private let displayName: String?
    private let previewTopic: (SharedQuizCreated) -> String?
    private let present: (ShareTextItem) -> Void
    private var loadTask: Task<Void, Never>?
    private var created: SharedQuizCreated?

    /// - Parameters:
    ///   - source: what a new link is made from; nil when `token` is the link.
    ///   - token: the link already exists (the friend's side, or a pack sent earlier).
    ///   - previewTopic: the share sheet's title (default: the pack's name);
    ///     nil = "A quiz in Trubbo".
    init(
        network: NetworkServiceProtocol,
        source: Source?,
        token: String? = nil,
        displayName: String? = PlayerNameStore().playerName(accountName: KeychainTokenStore().load()?.accountName),
        previewTopic: @escaping (SharedQuizCreated) -> String? = { $0.title },
        present: @escaping (ShareTextItem) -> Void = { ShareSheetPresenter.present([$0]) }
    ) {
        self.network = network
        self.source = source
        self.token = token
        self.displayName = displayName
        self.previewTopic = previewTopic
        self.present = present
    }

    var isCreating: Bool { status == .creating }

    var failureMessage: String? {
        if case let .failed(message) = status { return message }
        return nil
    }

    /// Creates the link (once) and opens the share sheet with `message`
    /// (text B) built for it.
    @discardableResult
    func send(message: @escaping (SharedQuizCreated) -> String) -> Task<Void, Never> {
        Task { await performSend(message: message) }
    }

    /// The comparison again (the screen appears, the app returns to the
    /// foreground). Nothing before a link exists.
    @discardableResult
    func loadResults() -> Task<Void, Never> {
        loadTask?.cancel()
        let task = Task { await performLoad() }
        loadTask = task
        return task
    }

    private func performSend(message: (SharedQuizCreated) -> String) async {
        guard status != .creating else { return }
        status = .creating
        do {
            let created = try await createdLink()
            status = .idle
            present(ShareTextItem(text: message(created), title: SharedQuizMessage.previewTitle(topic: previewTopic(created)), url: created.url))
            await performLoad()
        } catch {
            Logger.network.error("Shared quiz link failed: \(error, privacy: .public)")
            status = .failed(Self.failureText(for: error))
        }
    }

    private func createdLink() async throws -> SharedQuizCreated {
        if let created { return created }
        let made: SharedQuizCreated
        switch source {
        case let .session(id):
            made = try await network.createSharedQuiz(sessionId: id, packId: nil, displayName: displayName)
        case let .pack(id):
            made = try await network.createSharedQuiz(sessionId: nil, packId: id, displayName: displayName)
        case nil:
            // The friend passes the same link on.
            guard let token else { throw NetworkError.sharedQuizUnavailable(.notShareable) }
            return try await network.sharedQuizResults(token: token).forwarded(token: token)
        }
        created = made
        token = made.token
        return made
    }

    private func performLoad() async {
        guard let token else { return }
        do {
            let results = try await network.sharedQuizResults(token: token)
            guard !Task.isCancelled else { return }
            rows = Self.rows(from: results.players)
            loadFailed = false
            hasLoaded = true
        } catch {
            loadFailed = rows.isEmpty
            // The comparison is extra: the screen keeps what it had.
            Logger.network.info("Shared quiz results skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func rows(from players: [SharedQuizPlayer]) -> [Row] {
        players.enumerated().map { index, player in
            Row(
                id: index,
                rank: index + 1,
                name: player.name,
                isYou: player.isYou,
                score: scoreText(player.score),
                marks: player.marks
            )
        }
    }

    /// "7", or "7.5" for a part-right answer (as the round end shows it).
    static func scoreText(_ score: Double) -> String {
        score == score.rounded() ? "\(Int(score))" : score.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static func failureText(for error: Error) -> String {
        if case let NetworkError.sharedQuizUnavailable(reason)? = error as? NetworkError, reason != .notFound {
            return reason.message
        }
        return String(localized: "Couldn't create the link. Try again.", bundle: .interface, locale: .interface, comment: "#232: making a shared quiz link failed (network or server)")
    }
}

private extension SharedQuizResults {
    /// The friend's own copy of the link they played, to send on.
    func forwarded(token: String) -> SharedQuizCreated {
        SharedQuizCreated(token: token, kind: kind, language: language, title: title, categories: categories, questionCount: questionCount)
    }
}
