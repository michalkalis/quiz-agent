//
//  CarPlayQuizController.swift
//  Hangs
//
//  #97 — CarPlay support. Drives the car's screen from the app's one
//  QuizViewModel: the phone and the car show the same round, and every button
//  here calls the same quiz action the phone's controls call.
//
//  Template tree (Apple caps voice-based conversational apps at 3 levels):
//  root = home or quiz voice template, swapped as rounds start and end;
//  one pushed level = the topic list.
//

#if CARPLAY
    import CarPlay
    import Combine
    import os

    @available(iOS 26.4, *)
    final class CarPlayQuizController: NSObject, CPInterfaceControllerDelegate {
        private let interfaceController: CPInterfaceController
        private let viewModel: QuizViewModel
        private let packOrderService: PackOrderServiceProtocol
        private lazy var homeTemplate = makeHomeTemplate()
        private lazy var quizTemplate = makeQuizTemplate()
        private var shownScreen: CarPlayScreen?
        private var changes: AnyCancellable?
        private var recheck: Task<Void, Never>?

        init(
            interfaceController: CPInterfaceController,
            viewModel: QuizViewModel,
            packOrderService: PackOrderServiceProtocol
        ) {
            self.interfaceController = interfaceController
            self.viewModel = viewModel
            self.packOrderService = packOrderService
            super.init()
        }

        func start() {
            interfaceController.delegate = self
            render()
            // objectWillChange fires BEFORE the change lands; the debounce reads
            // the settled state, and keeps state switches under the template's
            // rate limit (it ignores switches that come too fast).
            changes = viewModel.objectWillChange
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.render() }
        }

        func stop() {
            changes = nil
            recheck?.cancel()
        }

        /// A state can only be activated on a presented template, so a template
        /// that just appeared gets its state now.
        nonisolated func templateDidAppear(_: CPTemplate, animated _: Bool) {
            Task { @MainActor in self.render() }
        }

        // MARK: - Rendering

        private var currentScreen: CarPlayScreen {
            CarPlayScreen(.init(
                quizState: viewModel.quizState,
                isPaused: viewModel.isPaused,
                isThinkWindowOpen: viewModel.answerWindowRemaining > 0,
                showAnswerConfirmation: viewModel.showAnswerConfirmation,
                showPaywall: viewModel.showPaywall
            ))
        }

        /// Brings the car's screen to the quiz's current moment. It checks what the
        /// template really shows rather than what was last asked for: the template
        /// silently drops a state switch that comes too soon after it appeared or
        /// after the previous switch (seen on the CarPlay simulator: a blank home
        /// after launch, a stuck "Listening…" while the phone moved on).
        private func render() {
            let screen = currentScreen
            let (template, stateID): (CPVoiceControlTemplate, String) = switch screen {
            case let .home(state): (homeTemplate, state.rawValue)
            case let .quiz(state): (quizTemplate, state.rawValue)
            }
            if screen != shownScreen {
                shownScreen = screen
                Logger.quiz.info("🚗 CarPlay screen → \(String(describing: screen), privacy: .public)")
            }
            guard interfaceController.rootTemplate === template else {
                interfaceController.setRootTemplate(template, animated: false, completion: nil)
                return
            }
            guard template.activeStateIdentifier != stateID else { return }
            Logger.quiz.debug("🚗 CarPlay activates \(stateID, privacy: .public) over \(template.activeStateIdentifier ?? "none", privacy: .public)")
            template.activateVoiceControlState(withIdentifier: stateID)
            recheck?.cancel()
            recheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.render()
            }
        }

        // MARK: - Templates

        private func makeHomeTemplate() -> CPVoiceControlTemplate {
            let states = CarPlayScreen.Home.allCases.map { state -> CPVoiceControlState in
                let voiceState = CPVoiceControlState(
                    identifier: state.rawValue,
                    titleVariants: [Self.title(for: state)],
                    image: Self.symbol(for: state),
                    repeats: false
                )
                voiceState.actionButtons = buttons(for: state)
                return voiceState
            }
            return CPVoiceControlTemplate(voiceControlStates: states)
        }

        private func makeQuizTemplate() -> CPVoiceControlTemplate {
            let states = CarPlayScreen.Quiz.allCases.map { state -> CPVoiceControlState in
                let voiceState = CPVoiceControlState(
                    identifier: state.rawValue,
                    titleVariants: [Self.title(for: state)],
                    image: Self.symbol(for: state),
                    repeats: false
                )
                voiceState.actionButtons = buttons(for: state)
                return voiceState
            }
            let template = CPVoiceControlTemplate(voiceControlStates: states)
            template.leadingNavigationBarButtons = [
                CPBarButton(
                    title: String(localized: "End quiz", comment: "CarPlay: ends the running quiz round early"),
                    handler: Self.onMain { [weak self] in
                        guard let self else { return }
                        Task { await self.viewModel.endQuizWithResults() }
                    }
                ),
            ]
            return template
        }

        private func buttons(for state: CarPlayScreen.Home) -> [CPButton] {
            switch state {
            case .ready:
                [button(Self.startTitle, "play.fill") { $0.startRound() }, topicsButton()]
            case .finished:
                [button(String(localized: "Play Again", comment: "CarPlay: starts another round after one ended"), "arrow.clockwise") { $0.viewModel.playAgain() }, topicsButton()]
            case .failed:
                [button(String(localized: "Try again", comment: "CarPlay: retries after an error"), "arrow.clockwise") { $0.viewModel.retryFromErrorScreen() }, topicsButton()]
            case .limitReached:
                []
            }
        }

        private func buttons(for state: CarPlayScreen.Quiz) -> [CPButton] {
            switch state {
            case .speaking, .listening:
                [button(String(localized: "Pause", comment: "CarPlay: pauses the quiz"), "pause.fill") { $0.pause() },
                 button(String(localized: "Skip", comment: "CarPlay: skips the current question"), "forward.fill") { $0.skip() }]
            case .thinking:
                []
            case .confirming:
                [button(String(localized: "Again", comment: "CarPlay: records the answer again"), "arrow.counterclockwise") { $0.viewModel.rerecordAnswer() },
                 button(String(localized: "Skip", comment: "CarPlay: skips the current question"), "forward.fill") { $0.skip() }]
            case .paused:
                [button(String(localized: "Continue", comment: "CarPlay: continues a paused quiz"), "play.fill") { $0.resume() }]
            }
        }

        private func topicsButton() -> CPButton {
            button(String(localized: "Categories", comment: "CarPlay: opens the list of quiz categories and packs"), "list.bullet") { $0.showTopics() }
        }

        private func button(_ title: String, _ symbol: String, action: @escaping @MainActor @Sendable (CarPlayQuizController) -> Void) -> CPButton {
            let button = CPButton(image: UIImage(systemName: symbol) ?? UIImage(), handler: Self.onMain { [weak self] in
                guard let self else { return }
                action(self)
            })
            button.title = title
            return button
        }

        // MARK: - Handlers

        /// CarPlay can call a template handler on its own XPC queue (the iOS 26.5
        /// simulator does for voice control buttons). This target is main-actor
        /// by default, so an inline handler would trap on the isolation check:
        /// handlers stay nonisolated and hop to the main actor themselves.
        private nonisolated static func onMain<Sender>(
            _ action: @escaping @MainActor @Sendable () -> Void
        ) -> @Sendable (Sender) -> Void {
            { _ in Task { @MainActor in action() } }
        }

        private nonisolated static func onMainListItem(
            _ action: @escaping @MainActor @Sendable () -> Void
        ) -> @Sendable (any CPSelectableListItem, @escaping () -> Void) -> Void {
            { _, completion in
                completion()
                Task { @MainActor in action() }
            }
        }

        // MARK: - Actions (the phone's own quiz actions)

        private func startRound() {
            // CarPlay starts without the phone's "only N questions left" alert —
            // nobody can answer it from the car; the round plays what there is.
            viewModel.beginQuizStart(skipAvailabilityCheck: true)
        }

        private func pause() {
            if case .showingResult = viewModel.quizState {
                viewModel.pauseQuiz() // holds the result's auto-advance
            } else {
                viewModel.enterPause()
            }
        }

        private func resume() {
            if case .showingResult = viewModel.quizState {
                viewModel.resumeAutoAdvance()
            } else {
                viewModel.exitPause()
            }
        }

        private func skip() {
            if case .showingResult = viewModel.quizState {
                viewModel.continueToNext()
            } else {
                Task { await viewModel.skipQuestion() }
            }
        }

        // MARK: - Topic list

        private func showTopics() {
            let categories = Config.categoryOptions.map { option in
                let item = CPListItem(text: option.display, detailText: nil)
                let categories = option.id.map { [$0] } ?? []
                item.handler = Self.onMainListItem { [weak self] in
                    self?.play(categories: categories)
                }
                return item
            }
            let list = CPListTemplate(
                title: String(localized: "Categories", comment: "CarPlay: opens the list of quiz categories and packs"),
                sections: [CPListSection(items: Array(categories.prefix(Int(CPListTemplate.maximumItemCount))))]
            )
            interfaceController.pushTemplate(list, animated: true, completion: nil)
            Task { await addPacks(to: list, categories: categories) }
        }

        /// The driver's own delivered packs, under the topics, once they load.
        private func addPacks(to list: CPListTemplate, categories: [CPListItem]) async {
            guard let orders = try? await packOrderService.listOrders() else { return }
            let packs = orders.filter(\.isPlayable).compactMap { order -> CPListItem? in
                guard let pack = order.packPlay else { return nil }
                let item = CPListItem(text: order.displayTitle, detailText: nil)
                item.handler = Self.onMainListItem { [weak self] in
                    self?.play(pack: pack)
                }
                return item
            }
            guard !packs.isEmpty else { return }
            // One list, capped by what this car's screen allows.
            let packRoom = max(0, Int(CPListTemplate.maximumItemCount) - categories.count)
            list.updateSections([
                CPListSection(items: categories),
                CPListSection(
                    items: Array(packs.prefix(packRoom)),
                    header: String(localized: "My packs", comment: "CarPlay: section header above the user's own quiz packs"),
                    sectionIndexTitle: nil
                ),
            ])
        }

        private func play(categories: [String]) {
            viewModel.settings.categories = categories
            closeList { [weak self] in self?.startRound() }
        }

        private func play(pack: PackPlay) {
            closeList { [weak self] in
                self?.viewModel.beginQuizStart(pack: pack, skipAvailabilityCheck: true)
            }
        }

        /// The round starts only once the list is gone: swapping the root
        /// template while the pop still ran left the car on a frozen template.
        private func closeList(then action: @escaping @MainActor @Sendable () -> Void) {
            interfaceController.popToRootTemplate(animated: false) { @Sendable _, _ in
                Task { @MainActor in action() }
            }
        }

        // MARK: - Copy

        static let startTitle = String(localized: "Start", comment: "CarPlay: starts a quiz round")

        static func title(for state: CarPlayScreen.Home) -> String {
            switch state {
            case .ready: String(localized: "Say \"start\"", comment: "CarPlay: home screen hint, the spoken command that starts a round")
            case .finished: String(localized: "Quiz finished", comment: "CarPlay: a quiz has ended")
            case .failed: String(localized: "Something went wrong", comment: "CarPlay: generic error state")
            case .limitReached: String(localized: "Continue on your phone", comment: "CarPlay: free questions used up, the upgrade screen is on the phone")
            }
        }

        static func title(for state: CarPlayScreen.Quiz) -> String {
            switch state {
            case .speaking: String(localized: "Trubbo is speaking", comment: "CarPlay: Trubbo is reading the question or result aloud")
            case .listening: String(localized: "Listening…", comment: "CarPlay: the microphone is open for the spoken answer")
            case .thinking: String(localized: "One moment", comment: "CarPlay: Trubbo is checking the answer or loading")
            case .confirming: String(localized: "Again or skip?", comment: "CarPlay: answer sheet, the driver can re-record or skip")
            case .paused: String(localized: "Paused", comment: "CarPlay: the quiz is paused")
            }
        }

        private static func symbol(for state: CarPlayScreen.Home) -> UIImage? {
            switch state {
            case .ready: image("play.circle.fill")
            case .finished: image("flag.checkered")
            case .failed: image("exclamationmark.triangle.fill")
            case .limitReached: image("iphone")
            }
        }

        private static func symbol(for state: CarPlayScreen.Quiz) -> UIImage? {
            switch state {
            case .speaking: image("waveform")
            case .listening: image("mic.fill")
            case .thinking: image("ellipsis")
            case .confirming: image("questionmark.bubble.fill")
            case .paused: image("pause.circle.fill")
            }
        }

        private static func image(_ symbol: String) -> UIImage? {
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 64, weight: .medium))
        }
    }
#endif
