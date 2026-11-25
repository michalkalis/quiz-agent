//
//  QuizViewModel+SpokenPrompts.swift
//  Hangs
//
//  #188 track G (founder picks 2026-10-06, audit K1 / K2 / D3 / D4): the
//  moments where the quiz used to go silent and wait for a tap. Each says ONE
//  short line in the quiz language, and no extra tone: "radšej menej zvukov".
//
//  - G1: the error screen says what happened and listens for "znova".
//  - G2: the free questions ran out: one line, then the paywall.
//  - G3: every round end says "Hotovo, 7 z 10. Znova, alebo domov?" and
//    listens for those two words (#243 decision 5, founder 2026-11-24); on
//    silence it asks once more, then waits. The recap says it after its
//    summary read.
//  - G4: "hear it" on the result reads the explanation, not the verdict again.
//
//  Lines are synthesized by the backend's generic TTS, like the retry prompt.
//

import Foundation
import os

extension QuizViewModel {
    /// A slow TTS round trip skips the line rather than holding the screen
    /// silent (same bound as the retry prompt).
    static let promptFetchTimeoutSeconds = 3

    /// #243 decision 5: how long the round end waits without hearing anything
    /// before it asks its question once more (the default think time is 10 s).
    static let roundEndReaskDelay: Duration = .seconds(8)

    private var promptLanguage: CommandLanguage {
        .forQuizLanguage(currentSession?.language ?? settings.language)
    }

    /// The words a quiz-end screen will act on, or none when nothing listens,
    /// so a spoken line never promises a word nobody hears.
    private func spokenCommands(_ commands: [VoiceCommand]) -> [VoiceCommand] {
        guard settings.voiceCommandsEnabled,
              voiceCommandCoordinator.commandAvailability == .ready else { return [] }
        return commands
    }

    private func errorPromptText(canRetry: Bool) -> String {
        SpokenPrompt.errorLine(
            commands: spokenCommands(canRetry ? [.again] : []),
            language: promptLanguage
        )
    }

    // MARK: - G1: error screen

    /// Called once the session exists: a dropped connection is the most common
    /// error, and by then the line can no longer be fetched.
    func prefetchErrorPrompt() {
        // A silent quiz never says it.
        guard !isSilentMode else { return }
        let text = errorPromptText(canRetry: true)
        guard prefetchedPromptAudio[text] == nil else { return }
        let language = currentSession?.language ?? settings.language
        Task { [weak self, networkService] in
            guard let audio = try? await networkService.synthesizeSpeech(text: text, language: language) else { return }
            self?.prefetchedPromptAudio[text] = audio
        }
    }

    /// Say the error line, then open the error screen's command window.
    func announceError() {
        let canRetry = activeErrorModel?.retryAction == .retryOperation
        let text = errorPromptText(canRetry: canRetry)
        taskBag.add(Task { [weak self] in
            guard let self else { return }
            if !isAudioMuted, let audio = await promptAudio(text) {
                guard !Task.isCancelled, quizState.isError else { return }
                await audioDeviceState.playAppSpeech(audio)
            }
            guard !Task.isCancelled, quizState.isError else { return }
            quizEndCommandsArmed = true
            await voiceCommandCoordinator.syncCommandListenerWindow()
        }, key: .quizEndPrompt)
    }

    /// Spoken "znova" on the error screen does what its primary button does;
    /// inert when the screen offers no retry.
    func retryFromErrorByVoice() async {
        guard activeErrorModel?.retryAction == .retryOperation else { return }
        if shouldRetryWithNewSession {
            playAgain()
        } else {
            await retryLastOperation()
        }
    }

    // MARK: - G2: free questions ran out

    /// One line before the paywall opens. The 429 itself proves the server
    /// is reachable, so no prefetch.
    func announceQuotaReached(upgradeAvailable: Bool = true) async {
        guard !isAudioMuted,
              let audio = await promptAudio(SpokenPrompt.quotaReachedLine(language: promptLanguage, upgradeAvailable: upgradeAvailable))
        else { return }
        await audioDeviceState.playAppSpeech(audio)
    }

    // MARK: - Free voice answers used up (2026-11-21)

    /// The once-a-month line, then the question screen's command window
    /// again (app speech closes it). Leaving the question cancels it.
    func announceVoiceLimit() {
        let questionId = currentQuestion?.id
        taskBag.add(Task { [weak self] in
            guard let self, !isAudioMuted,
                  let audio = await promptAudio(SpokenPrompt.voiceLimitLine(language: promptLanguage)),
                  !Task.isCancelled, currentQuestion?.id == questionId
            else { return }
            await audioDeviceState.playAppSpeech(audio)
            guard !Task.isCancelled, quizState == .askingQuestion else { return }
            await voiceCommandCoordinator.syncCommandListenerWindow()
        }, key: .voiceLimitPrompt)
    }

    // MARK: - G3: round end (#243 decision 5)

    /// Say "Hotovo, 7 z 10. Znova, alebo domov?", release the quiz session
    /// (music back to full volume), then listen on the quiet session like
    /// Home does. A line that cannot be fetched is skipped; the screen listens
    /// all the same. Heard nothing: the question once more, then silence.
    /// #240.9: `thenPaywall` = the round ended at the monthly limit; after
    /// the score the paywall follows (`showRoundEndPaywall`).
    func announceSetFinished(thenPaywall quotaLimit: QuotaLimitError? = nil) {
        roundEndLineStarted = true
        let commands = spokenCommands(VoiceCommandLexicon.commands(on: .setEnd))
        let text = SpokenPrompt.setFinishedLine(
            correct: sessionCorrectCount,
            total: currentSession?.maxQuestions ?? settings.numberOfQuestions,
            commands: commands,
            language: promptLanguage
        )
        let question = SpokenPrompt.setEndQuestion(commands: commands, language: promptLanguage)
        taskBag.add(Task { [weak self] in
            guard let self else { return }
            await sayAtRoundEnd(text)
            guard !Task.isCancelled, quizState == .finished else { return }
            if let quotaLimit { await showRoundEndPaywall(quotaLimit) }
            guard !Task.isCancelled, quizState == .finished else { return }
            audioService.deactivateSession()
            quizEndCommandsArmed = true
            await voiceCommandCoordinator.syncCommandListenerWindow()
            if let question { await reaskRoundEndOnSilence(question) }
        }, key: .quizEndPrompt)
    }

    /// The recap's summary read (or the row read that replaced it) ended or
    /// was stopped: the round-end line follows the first one; after a later
    /// read the screen listens again (app speech closed the window).
    func resumeRoundEndAfterRecapRead() async {
        guard quizState == .finished else { return }
        if !roundEndLineStarted {
            announceSetFinished()
        } else if quizEndCommandsArmed {
            await voiceCommandCoordinator.syncCommandListenerWindow()
        }
    }

    /// Spoken "znova" at a round end does what Play Again does. The daily
    /// challenge end has no Play Again (one challenge a day), so there it
    /// starts an ordinary round, as Home's Start does.
    func playAgainFromRoundEnd() {
        if activeDaily != nil {
            beginQuizStart()
        } else {
            playAgain()
        }
    }

    private func sayAtRoundEnd(_ text: String) async {
        guard !isAudioMuted, let audio = await promptAudio(text),
              !Task.isCancelled, quizState == .finished else { return }
        await audioDeviceState.playAppSpeech(audio)
    }

    /// Founder decision 5: "pri tichu sa raz spýta, potom čaká". Only while
    /// the screen still listens, nothing was heard, and nothing else talks
    /// or covers it (a recap read, the paywall).
    private func reaskRoundEndOnSilence(_ question: String) async {
        let heardBefore = voiceCommandCoordinator.transcriptsHeard
        try? await clock.sleep(for: Self.roundEndReaskDelay)
        guard !Task.isCancelled, quizState == .finished, !isAudioMuted, !isNarratingRecap, !showPaywall,
              voiceCommandCoordinator.currentCommandScreen == .setEnd,
              voiceCommandCoordinator.transcriptsHeard == heardBefore
        else { return }
        await sayAtRoundEnd(question)
        guard !Task.isCancelled, quizState == .finished else { return }
        await voiceCommandCoordinator.syncCommandListenerWindow()
    }

    // MARK: - G4: "hear it" reads the explanation

    /// Read the result's explanation aloud, then give the result screen its
    /// listener back. A tap is explicit, so it plays even when muted, as the
    /// replay it replaces did. The result waits while it is read.
    func readExplanationAloud(_ explanation: String) {
        // Silent mode reads nothing; the result offers no "hear it" there.
        guard !isSilentMode else { return }
        holdResultAutoAdvance()
        holdResultAutoAdvance()
        taskBag.add(Task { [weak self] in
            guard let self else { return }
            var outcome = ReadAloudOutcome()
            for chunk in Self.splitForTTS(explanation) {
                guard let audio = try? await networkService.synthesizeSpeech(
                    text: chunk, language: currentSession?.language ?? settings.language
                ) else {
                    outcome.failed = true
                    break
                }
                guard !Task.isCancelled, quizState.isShowingResult else { break }
                await audioDeviceState.playAppSpeech(audio)
                outcome.played = true
            }
            guard !Task.isCancelled else { return }
            if quizState.isShowingResult { noteReadAloud(.explanation, outcome) }
            await audioDeviceState.startSilenceDetectionListening()
        }, key: .explanationReadOut)
    }

    /// #235 F3: a read that played clears the note; one that could not fetch
    /// anything shows it next to the button that asked.
    func noteReadAloud(_ target: ReadAloudTarget, _ outcome: ReadAloudOutcome) {
        if outcome.played {
            readAloudFailure = nil
        } else if outcome.failed {
            readAloudFailure = target
        }
    }

    // MARK: - #243.3: phase prompts

    /// Questions at the start of a quiz that hear the longer think line with
    /// the seconds (founder 2026-11-24: the first two).
    static let longThinkPromptQuestions = 2

    /// "Think." / "Answer." in the app voice, from the bundle. Nothing in a
    /// silent quiz or with read-aloud off: the screen says the phase there.
    /// After an answer window heard nothing it is "Think more." (#243.4).
    func announcePhase(_ cue: QuizTimersController.PhaseCue) async {
        // #243.4: taken before the mute guard, so it never reaches a later window.
        let thinksMore = recordingCoordinator.takeThinkMore(questionId: currentQuestion?.id)
        guard !isSilentMode, !isAudioMuted else {
            // The read's tail left the listener to this line; no line, so
            // bring it up here (read-aloud switched off as the read ended).
            if case .thinkStart = cue { await armListenerLeftToThinkLine() }
            return
        }
        // A line is a new clip, and a new clip stops the one playing: said
        // over a replay the player tapped, it would cut the question off.
        switch cue {
        case let .thinkStart(seconds):
            // The replay took this window's start over (a tap wins): the
            // window drains under it unannounced, as it did before #243.3.
            guard !isPlayingQuestionTTS else { return }
            let long = questionScreenNumber <= Self.longThinkPromptQuestions
            await playPhasePrompt(thinksMore ? .thinkMore : .think(seconds: long ? seconds : nil))
            // App speech closes the command window; thinking listens again.
            guard !Task.isCancelled, quizState == .askingQuestion else { return }
            await voiceCommandCoordinator.syncCommandListenerWindow()
        case .answerStart:
            // The hands-free mic waits for a read in progress (#185); the line
            // waits with it, so it still comes right before the mic.
            guard await recordingCoordinator.resolveQuestionReadOut(for: .autoRecord) == .proceed,
                  !Task.isCancelled, quizState == .askingQuestion
            else { return }
            await playPhasePrompt(.answer)
        }
    }

    /// The question read hands the listener to the think line when that line
    /// plays right after it (`AudioDeviceState.playQuestionAudio`): arming it
    /// between the two only to tear it down for the line was a long, audible
    /// pause (founder, TF b92). Same conditions the think window and
    /// `announcePhase` speak under.
    var thinkLineFollowsRead: Bool {
        quizState == .askingQuestion
            && !isSilentMode
            && !isAudioMuted
            && !quizTimersController.isPaused
            && !quizTimersController.isHeldForTyping
            && settings.thinkingTime != 0
    }

    /// The think window opened without its line although the read left the
    /// listener to it: commands still work while the player thinks.
    private func armListenerLeftToThinkLine() async {
        guard quizState == .askingQuestion,
              !silenceDetectionService.isListening,
              !silenceDetectionService.isStartingListening
        else { return }
        await voiceCommandCoordinator.syncCommandListenerWindow()
    }

    func playPhasePrompt(_ prompt: PhasePrompt) async {
        guard let audio = prompt.audio(language: promptLanguage) else {
            Logger.audio.warning("🔈 Phase prompt \(prompt.resourceName, privacy: .public) missing from the bundle")
            return
        }
        attemptLedger.record(.prompt, "phase", prompt.resourceName)
        recordingCoordinator.noteSpokenLine(prompt.text(language: promptLanguage)) // #243.4 echo guard
        await audioDeviceState.playAppSpeech(audio)
    }

    // MARK: - Fetch

    private func promptAudio(_ text: String) async -> Data? {
        if let cached = prefetchedPromptAudio[text] { return cached }
        let language = currentSession?.language ?? settings.language
        do {
            return try await withUserFacingTimeout(seconds: Self.promptFetchTimeoutSeconds, clock: clock) {
                try await self.networkService.synthesizeSpeech(text: text, language: language)
            }
        } catch {
            Logger.audio.warning("🔈 Spoken prompt fetch failed: \(error, privacy: .public)")
            return nil
        }
    }
}
