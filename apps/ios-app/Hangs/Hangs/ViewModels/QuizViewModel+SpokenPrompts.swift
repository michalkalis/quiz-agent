//
//  QuizViewModel+SpokenPrompts.swift
//  Hangs
//
//  #188 track G (founder picks 2026-10-06, audit K1 / K2 / D3 / D4): the
//  moments where the quiz used to go silent and wait for a tap. Each says ONE
//  short line in the quiz language, and no extra tone: "radšej menej zvukov".
//
//  - G1: the error screen says what happened and listens for "znova" / "stop".
//  - G2: the free questions ran out: one line, then the paywall.
//  - G3: the per-question flow's set end says the score and listens for
//    "znova" / "domov". The end-of-set recap already narrates itself.
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
            commands: spokenCommands(canRetry ? [.again, .stop] : [.stop]),
            language: promptLanguage
        )
    }

    // MARK: - G1: error screen

    /// Called once the session exists: a dropped connection is the most common
    /// error, and by then the line can no longer be fetched.
    func prefetchErrorPrompt() {
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
            beginQuizStart()
        } else {
            await retryLastOperation()
        }
    }

    // MARK: - G2: free questions ran out

    /// One line before the paywall opens. The 429 itself proves the server
    /// is reachable, so no prefetch.
    func announceQuotaReached() async {
        guard !isAudioMuted,
              let audio = await promptAudio(SpokenPrompt.quotaReachedLine(language: promptLanguage))
        else { return }
        await audioDeviceState.playAppSpeech(audio)
    }

    // MARK: - G3: set end (per-question flow)

    /// Say the score, release the quiz session (music back to full volume),
    /// then listen on the quiet session like Home does.
    func announceSetFinished() {
        let text = SpokenPrompt.setFinishedLine(
            correct: sessionCorrectCount,
            total: currentSession?.maxQuestions ?? settings.numberOfQuestions,
            commands: spokenCommands([.again, .home]),
            language: promptLanguage
        )
        taskBag.add(Task { [weak self] in
            guard let self else { return }
            if !isAudioMuted, let audio = await promptAudio(text) {
                guard !Task.isCancelled, quizState == .finished else { return }
                await audioDeviceState.playAppSpeech(audio)
            }
            guard !Task.isCancelled, quizState == .finished else { return }
            audioService.deactivateSession()
            quizEndCommandsArmed = true
            await voiceCommandCoordinator.syncCommandListenerWindow()
        }, key: .quizEndPrompt)
    }

    // MARK: - G4: "hear it" reads the explanation

    /// Read the result's explanation aloud, then give the result screen its
    /// listener back. A tap is explicit, so it plays even when muted, as the
    /// replay it replaces did.
    func readExplanationAloud(_ explanation: String) {
        taskBag.add(Task { [weak self] in
            guard let self else { return }
            for chunk in Self.splitForTTS(explanation) {
                guard let audio = try? await networkService.synthesizeSpeech(
                    text: chunk, language: currentSession?.language ?? settings.language
                ),
                      !Task.isCancelled, quizState.isShowingResult else { break }
                await audioDeviceState.playAppSpeech(audio)
            }
            guard !Task.isCancelled else { return }
            await audioDeviceState.startSilenceDetectionListening()
        }, key: .explanationReadOut)
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
