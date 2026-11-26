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
    /// Host: a pause or resume is on its way to the server (#224.4).
    @Published var isChangingPause = false
    /// Guest: this phone reads each question aloud itself (#230.2). On by
    /// default after a link join (a friend in another city), off next to the host.
    @Published var guestReadsAloud = false
    /// Host without an account name: asked once before the room exists.
    @Published var isAskingHostName = false

    /// The host's rules (#213.8), kept on the device; changed only through
    /// the `set…` methods in RoomViewModel+Settings, which keep the room in step.
    @Published var settings: MultiplayerSettings
    /// Host: a rules change is on its way to the server.
    @Published var isSavingSettings = false
    /// #232 (5A): what the room plays; the host changes it in the lobby.
    @Published var content: RoomContent = .categories

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
    /// #232 (5A): the host may pick a finished custom pack (server switch).
    let packsEnabled: () -> Bool
    /// #249.1: the served extra categories (the solo list), offered when their switch is on.
    let extraCategories: @MainActor () -> [ExtraCategory]
    private let calls: CallStatusProviding
    private let isOffCellular: () async -> Bool
    /// #235 F5: a leave the server did not get is kept and sent again later.
    private let pendingLeaves: PendingRoomLeaveStore

    private(set) var invite: RoomInvite?
    private(set) var questionsById: [String: Question] = [:]
    private(set) var answerDeadline: AnyClock<Duration>.Instant?
    /// The whole answer window of the open question, for the countdown bar.
    private(set) var answerWindowSeconds: Int?
    /// #240.9: when this phone first saw the open question being read aloud.
    private(set) var readingSince: AnyClock<Duration>.Instant?
    /// #240.9: the host's phone reported how this game ended (once per game).
    var closeReported = false
    private var awayReported: Set<String> = []
    private var pollFailures = 0
    /// The player closed the game: a reply still on its way changes nothing (#235.2).
    private(set) var hasLeft = false
    private var pollTask: Task<Void, Never>?
    private var nearbyTask: Task<Void, Never>?
    var readTask: Task<Void, Never>?
    var advanceTask: Task<Void, Never>?
    var readQuestionId: String?
    var advanceQuestionId: String?
    var questionAudioPath: String?
    var guestReadTask: Task<Void, Never>?
    var guestReadQuestionId: String?
    private var draftWatcher: Task<Void, Never>?
    private var draftWatcherQuestionId: String?

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
        isOffCellular: @escaping () async -> Bool = LocalNetworkCheck.isOffCellular,
        packsEnabled: @escaping () -> Bool = { false },
        extraCategories: @escaping @MainActor () -> [ExtraCategory] = { [] },
        pendingLeaves: PendingRoomLeaveStore = PendingRoomLeaveStore()
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
        self.accountName = PlayerNameStore.firstName(of: accountName)
        self.excludedQuestionIds = excludedQuestionIds
        self.names = names
        self.calls = calls ?? CallMonitor()
        self.clock = clock
        self.isOffCellular = isOffCellular
        self.packsEnabled = packsEnabled
        self.extraCategories = extraCategories
        self.pendingLeaves = pendingLeaves
        playerName = names.playerName(accountName: accountName, languageCode: languageCode)
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
    /// #224.4: the host stays on this reveal; every phone says so.
    var isPaused: Bool { round?.isPaused == true }
    /// After a reveal the host's phone moves on by itself after this long
    /// (solo's pause). #243.8: solo's "right after the verdict" (0) and "wait
    /// for next" (-1) have no length; a room reveal has no spoken verdict to
    /// follow and must never count down from 0 or below, so both get the
    /// reveal's reading time.
    var autoAdvanceSeconds: Int {
        solo.autoAdvanceDelay > 0 ? solo.autoAdvanceDelay : Self.revealReadingSeconds
    }

    /// The reading time of a reveal when solo's pace names none (#243.8):
    /// the 8 s every room had before the presets.
    static let revealReadingSeconds = 8
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

    /// #216.2: the Together tab came on screen; each visit gets a fresh room.
    func tabOpened() {
        analytics.track(.togetherOpened)
        // #235 F5: a leave an earlier game could not send goes out now.
        Task { [pendingLeaves, rooms, network] in await pendingLeaves.resend(rooms: rooms, network: network) }
    }

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
        if case .token = invite { guestReadsAloud = true } else { guestReadsAloud = false }
        isWorking = true
        defer { isWorking = false }
        do {
            let joined = try await rooms.joinRoom(invite, displayName: playerName)
            // Closed while the join was on its way: drop out again (#235.2).
            guard !hasLeft else {
                if let you = joined.you { try? await rooms.removePlayer(roomId: joined.roomId, participantId: you) }
                return
            }
            apply(joined)
            startPolling()
        } catch {
            guard !hasLeft else { return }
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

    /// #249.3: the answer time ran out with text typed but not sent: send it
    /// once, inside the server's grace. Never when an answer is in flight (a
    /// tap right at the end) or already in. A failure stays silent on purpose:
    /// the screen already says "Time's up" and the next poll brings the reveal.
    func sendDraftAtTimeout(questionId: String) async {
        let text = typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let roomId = state?.roomId, let round,
              round.questionId == questionId, round.phase == .answering,
              round.yourAnswer == nil, submittingAnswer == nil, !hasLeft,
              questionsById[questionId]?.isMultipleChoice != true
        else { return }
        let answer = String(text.prefix(scalars: Self.maxAnswerLength))
        submittingAnswer = answer
        defer { submittingAnswer = nil }
        do {
            try apply(await rooms.answer(roomId: roomId, questionId: questionId, answer: answer))
        } catch {
            await refresh()
        }
    }

    /// Waits for the open question's answer deadline (which each poll may
    /// move) and then sends the draft. One watcher per question.
    private func watchDraftDeadline(questionId: String) {
        guard draftWatcherQuestionId != questionId else { return }
        draftWatcherQuestionId = questionId
        draftWatcher?.cancel()
        draftWatcher = Task { [weak self] in
            while let self, !Task.isCancelled {
                guard let deadline = answerDeadline, round?.questionId == questionId else { return }
                if clock.now >= deadline {
                    await sendDraftAtTimeout(questionId: questionId)
                    return
                }
                do { try await clock.sleep(until: deadline) } catch { return }
            }
        }
    }

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
    /// The server is told in the background: closing never waits on the
    /// network. A leave that does not arrive is kept and sent again (#235 F5).
    func leave() async {
        hasLeft = true
        stopAll()
        if role == .guest { await audio.stopPlayback() }
        reportClose(state?.status == .finished ? .finished : state?.status == .playing ? .hostLeft : .neverStarted)
        guard let roomId = state?.roomId ?? created?.roomId else { return }
        let leave: PendingRoomLeave
        if role == .guest, let you = state?.you, !hasEnded {
            leave = .guest(roomId: roomId, participantId: you)
        } else if role == .host, let created, state?.status != .finished {
            leave = .host(sessionId: created.sessionId)
        } else {
            return
        }
        pendingLeaves.save(leave)
        Task { [pendingLeaves, rooms, network] in await pendingLeaves.deliver(leave, rooms: rooms, network: network) }
    }

    /// #232 (5A): the lobby moved to a room with other content.
    func moveToRoom(_ room: RoomCreated) {
        created = room
        state = nil
        readingSince = nil
    }

    func stopAll() {
        stopNearbySearch()
        pollTask?.cancel()
        pollTask = nil
        readTask?.cancel()
        guestReadTask?.cancel()
        advanceTask?.cancel()
        draftWatcher?.cancel()
        draftWatcherQuestionId = nil
        autoAdvanceLeft = nil
    }

    // MARK: - Polling

    /// Keeps polling on the final screen too: the host may start another game
    /// with everyone (#240.9), and this phone then follows into its lobby.
    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                if self.hasEnded || self.hasLeft { return }
                do { try await self.clock.sleep(for: Self.pollInterval) } catch { return }
            }
        }
    }

    func refresh() async {
        guard let roomId = state?.roomId ?? created?.roomId else { return }
        do {
            try apply(await rooms.roomState(roomId: roomId, since: state?.version))
        } catch NetworkError.serverError(statusCode: 404, _) {
            // A finished game whose room expired keeps its ranking on screen.
            if state?.status == .finished {
                pollTask?.cancel()
                pollTask = nil
            } else {
                reportClose(.expired)
                end()
            }
        } catch is CancellationError {
        } catch {
            pollFailures += 1
            setConnectionTrouble(pollFailures >= Self.toleratedPollFailures)
        }
    }

    func apply(_ new: RoomState) {
        guard !hasLeft else { return }
        pollFailures = 0
        setConnectionTrouble(false)
        guard new.changed else { return }
        if let old = state, new.version < old.version { return }
        let previousQuestionId = round?.questionId
        state = new
        if let question = new.question { questionsById[question.id] = question }
        if let round = new.round {
            if round.questionId != previousQuestionId {
                typedAnswer = ""
                draftWatcherQuestionId = nil
                answerWindowSeconds = nil
                readingSince = nil
            }
            if round.phase == .reading, readingSince == nil { readingSince = clock.now }
            answerDeadline = round.phase == .answering
                ? round.remainingMs.map { clock.now.advanced(by: .milliseconds($0)) }
                : nil
            if round.phase == .answering, round.yourAnswer == nil { watchDraftDeadline(questionId: round.questionId) }
            if answerWindowSeconds == nil, round.phase == .answering, let ms = round.remainingMs {
                answerWindowSeconds = max(1, (ms + 999) / 1000)
            }
        }
        if role == .host { hostReact(to: new) }
        if role == .guest { guestReact(to: new) }
        if new.finishedReason == "usage_limit" { quotaReached = true }
    }

    /// Assigns only a real change: every write to a published value redraws the
    /// room, and a redraw each poll rebuilds an open rules menu under the
    /// host's finger, so the pick is lost.
    private func setConnectionTrouble(_ trouble: Bool) {
        if connectionTrouble != trouble { connectionTrouble = trouble }
    }

    private func end() {
        guard !hasEnded else { return }
        stopAll()
        hasEnded = true
    }
}
