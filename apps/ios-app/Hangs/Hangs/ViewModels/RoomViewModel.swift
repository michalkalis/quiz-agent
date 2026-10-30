//
//  RoomViewModel.swift
//  Hangs
//
//  #212: one phone's side of a same-room game (host or guest).
//

import Clocks
import Combine
import Foundation
import os

/// The server owns the game: every phone polls the room about once a second
/// and draws what it says. The host's phone also reads each question aloud,
/// starts the answer time and moves on. Answer time counts down from the
/// server's `remaining_ms`, never from the phone's own clock.
@MainActor
final class RoomViewModel: ObservableObject, Identifiable {
    enum Role: Equatable { case host, guest }

    enum Screen: Equatable {
        /// Host a game, or pick one on this Wi-Fi.
        case start
        case lobby
        case question
        /// Per-question reveal (`reveal_mode == question`).
        case reveal
        /// The question closed, results come at the end (`reveal_mode == round`).
        case roundWait
        case finished
        /// The game is gone: the host ended it or removed this player.
        case ended
    }

    enum NearbyStatus: Equatable { case searching, found, offWiFi, failed }

    nonisolated let id = UUID()

    @Published var role: Role?
    @Published private(set) var state: RoomState?
    /// Host only: the room's id and the token in its QR code and link.
    @Published var created: RoomCreated?
    @Published private(set) var nearby: [NearbyRoom] = []
    @Published private(set) var nearbyStatus: NearbyStatus = .searching
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published private(set) var hasEnded = false
    /// The host's monthly questions ran out (start or mid-game).
    @Published var quotaReached = false
    @Published private(set) var playerName: String
    /// The answer in flight (option key or typed text), so the tapped tile
    /// spins and nothing else takes a tap.
    @Published private(set) var submittingAnswer: String?
    @Published var typedAnswer = ""
    @Published private(set) var connectionTrouble = false
    /// Host: its phone is reading the question aloud.
    @Published var isReadingAloud = false
    /// Host: seconds until the phone moves on by itself after a reveal.
    @Published var autoAdvanceLeft: Int?
    /// Host without an account name: asked once before the room exists.
    @Published var isAskingHostName = false

    /// The host's rules (#213.8), kept on the device; changed only through
    /// the `set…` methods in RoomViewModel+Settings, which keep the room in step.
    @Published var settings: MultiplayerSettings
    /// Host: a rules change is on its way to the server.
    @Published var isSavingSettings = false

    let settingsStore: MultiplayerSettingsStore
    let analytics: AnalyticsClient
    let rooms: RoomServiceProtocol
    let network: NetworkServiceProtocol
    let audio: AudioServiceProtocol
    let audioMode: AudioMode
    let solo: QuizSettings
    let deviceId: String
    let accountName: String?
    let excludedQuestionIds: () -> [String]
    let clock: AnyClock<Duration>
    let names: PlayerNameStore
    private let calls: CallStatusProviding
    private let isOffCellular: () async -> Bool

    private(set) var invite: RoomInvite?
    private(set) var questionsById: [String: Question] = [:]
    private(set) var answerDeadline: AnyClock<Duration>.Instant?
    /// The whole answer window of the open question, for the countdown bar.
    private(set) var answerWindowSeconds: Int?
    private var awayReported: Set<String> = []
    private var pollFailures = 0
    private var pollTask: Task<Void, Never>?
    private var nearbyTask: Task<Void, Never>?
    var readTask: Task<Void, Never>?
    var advanceTask: Task<Void, Never>?
    var readQuestionId: String?
    var advanceQuestionId: String?
    var questionAudioPath: String?

    static let pollInterval: Duration = .seconds(1)
    static let nearbyInterval: Duration = .seconds(3)
    /// Polls that may fail in a row before the screen says the connection is shaky.
    static let toleratedPollFailures = 3

    init(
        rooms: RoomServiceProtocol,
        network: NetworkServiceProtocol,
        audio: AudioServiceProtocol,
        audioMode: AudioMode = .default,
        solo: QuizSettings,
        deviceId: String,
        accountName: String? = nil,
        excludedQuestionIds: @escaping () -> [String] = { [] },
        names: PlayerNameStore = PlayerNameStore(),
        settingsStore: MultiplayerSettingsStore = MultiplayerSettingsStore(),
        analytics: AnalyticsClient = NoopAnalyticsClient(),
        calls: CallStatusProviding? = nil,
        clock: AnyClock<Duration> = .continuous,
        languageCode: String? = Locale.current.language.languageCode?.identifier,
        isOffCellular: @escaping () async -> Bool = LocalNetworkCheck.isOffCellular
    ) {
        self.rooms = rooms
        self.network = network
        self.audio = audio
        self.audioMode = audioMode
        self.solo = solo
        self.settingsStore = settingsStore
        settings = settingsStore.load()
        self.analytics = analytics
        self.deviceId = deviceId
        self.accountName = accountName.flatMap { $0.split(separator: " ").first.map(String.init) }
        self.excludedQuestionIds = excludedQuestionIds
        self.names = names
        self.calls = calls ?? CallMonitor()
        self.clock = clock
        self.isOffCellular = isOffCellular
        playerName = names.chosenName ?? PlayerNameStore.automaticName(languageCode: languageCode)
    }

    // MARK: - What the screen shows

    var screen: Screen {
        if hasEnded { return .ended }
        guard let role else { return .start }
        guard let status = state?.status else { return role == .host || invite != nil ? .lobby : .start }
        switch status {
        case .lobby: return .lobby
        case .finished: return .finished
        case .playing:
            guard let round = state?.round, round.phase == .revealed else { return .question }
            return state?.revealMode == .round ? .roundWait : .reveal
        }
    }

    var isHost: Bool { role == .host }
    /// After a reveal the host's phone moves on by itself after this long (solo's pause).
    var autoAdvanceSeconds: Int { solo.autoAdvanceDelay }
    var players: [RoomState.Player] { state?.players ?? [] }
    var me: RoomState.Player? { players.first { $0.participantId == state?.you } }
    var host: RoomState.Player? { players.first(where: \.isHost) }
    var round: RoomState.Round? { state?.round }
    var question: Question? { round.flatMap { questionsById[$0.questionId] } ?? state?.question }

    /// The answer field and the options take input.
    var canAnswer: Bool {
        guard let round, round.phase == .reading || round.phase == .answering,
              round.yourAnswer == nil, submittingAnswer == nil
        else { return false }
        return secondsLeft().map { $0 > 0 } ?? true
    }

    /// Whole seconds of answer time left; nil while the host reads aloud.
    func secondsLeft() -> Int? {
        guard let answerDeadline, round?.phase == .answering else { return nil }
        let left = clock.now.duration(to: answerDeadline)
        return max(0, Int((left.timeInterval).rounded(.up)))
    }

    // MARK: - Guest

    /// Keeps the "games on this Wi-Fi" list fresh while the start screen is up.
    func startNearbySearch() {
        nearbyTask?.cancel()
        nearbyTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.screen == .start {
                await self.searchNearby()
                do { try await self.clock.sleep(for: Self.nearbyInterval) } catch { return }
            }
        }
    }

    func stopNearbySearch() {
        nearbyTask?.cancel()
        nearbyTask = nil
    }

    func searchNearby() async {
        guard await isOffCellular() else {
            nearbyStatus = .offWiFi
            nearby = []
            return
        }
        do {
            nearby = try await rooms.nearbyRooms()
            nearbyStatus = .found
        } catch {
            nearbyStatus = nearby.isEmpty ? .failed : .found
        }
    }

    func join(_ invite: RoomInvite) async {
        stopNearbySearch()
        self.invite = invite
        role = .guest
        isWorking = true
        defer { isWorking = false }
        do {
            try apply(await rooms.joinRoom(invite, displayName: playerName))
            startPolling()
        } catch {
            role = nil
            self.invite = nil
            errorMessage = Self.joinMessage(for: error)
            startNearbySearch()
        }
    }

    /// A new name for this player, kept for the next game. A guest already in
    /// the lobby joins again under it, which renames them for everyone.
    func rename(to name: String) async {
        guard let clean = PlayerNameStore.cleaned(name), clean != playerName else { return }
        names.save(clean)
        playerName = clean
        guard role == .guest, let invite, state?.status == .lobby else { return }
        do {
            try apply(await rooms.joinRoom(invite, displayName: clean))
        } catch {
            errorMessage = Self.genericMessage
        }
    }

    // MARK: - Everyone

    func submitOption(key: String) async {
        await submit(key)
    }

    func submitTypedAnswer() async {
        let text = typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await submit(text.prefix(scalars: Self.maxAnswerLength))
    }

    static let maxAnswerLength = 200

    private func submit(_ answer: String) async {
        guard canAnswer, let roomId = state?.roomId, let round else { return }
        submittingAnswer = answer
        defer { submittingAnswer = nil }
        do {
            try apply(await rooms.answer(roomId: roomId, questionId: round.questionId, answer: answer))
        } catch NetworkError.serverError(statusCode: 409, _) {
            // Already answered on another try, or the time ran out: the room knows.
            await refresh()
        } catch {
            errorMessage = Self.genericMessage
        }
    }

    /// #212.4: leaving the app while a question is open (and not yet answered)
    /// is reported once per question; never during a phone call. No penalty,
    /// only the host sees it at the end.
    func appMovedToBackground() {
        guard let roomId = state?.roomId, let round,
              round.phase == .reading || round.phase == .answering,
              round.yourAnswer == nil, submittingAnswer == nil,
              !calls.isOnCall, !awayReported.contains(round.questionId)
        else { return }
        awayReported.insert(round.questionId)
        Task { try? await rooms.reportAway(roomId: roomId, questionId: round.questionId) }
    }

    func appBecameActive() {
        guard pollTask != nil else { return }
        Task { await refresh() }
    }

    /// Leaves the game: a guest drops out of the room, a host ends it for
    /// everyone unless it is already over.
    func leave() async {
        stopAll()
        guard let roomId = state?.roomId ?? created?.roomId else { return }
        if role == .guest, let you = state?.you, !hasEnded {
            try? await rooms.removePlayer(roomId: roomId, participantId: you)
        } else if role == .host, let created, state?.status != .finished {
            try? await network.endSession(sessionId: created.sessionId)
        }
    }

    func stopAll() {
        stopNearbySearch()
        pollTask?.cancel()
        pollTask = nil
        readTask?.cancel()
        advanceTask?.cancel()
        autoAdvanceLeft = nil
    }

    // MARK: - Polling

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                if self.state?.status == .finished || self.hasEnded { return }
                do { try await self.clock.sleep(for: Self.pollInterval) } catch { return }
            }
        }
    }

    func refresh() async {
        guard let roomId = state?.roomId ?? created?.roomId else { return }
        do {
            try apply(await rooms.roomState(roomId: roomId, since: state?.version))
        } catch NetworkError.serverError(statusCode: 404, _) {
            end()
        } catch is CancellationError {
        } catch {
            pollFailures += 1
            connectionTrouble = pollFailures >= Self.toleratedPollFailures
        }
    }

    func apply(_ new: RoomState) {
        pollFailures = 0
        connectionTrouble = false
        guard new.changed else { return }
        if let old = state, new.version < old.version { return }
        let previousQuestionId = round?.questionId
        state = new
        if let question = new.question { questionsById[question.id] = question }
        if let round = new.round {
            if round.questionId != previousQuestionId {
                typedAnswer = ""
                answerWindowSeconds = nil
            }
            answerDeadline = round.phase == .answering
                ? round.remainingMs.map { clock.now.advanced(by: .milliseconds($0)) }
                : nil
            if answerWindowSeconds == nil, round.phase == .answering, let ms = round.remainingMs {
                answerWindowSeconds = max(1, (ms + 999) / 1000)
            }
        }
        if role == .host { hostReact(to: new) }
        if new.finishedReason == "usage_limit" { quotaReached = true }
    }

    private func end() {
        guard !hasEnded else { return }
        stopAll()
        hasEnded = true
    }
}
