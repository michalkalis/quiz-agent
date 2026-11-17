//
//  CommandPermissionTests.swift
//  HangsTests
//
//  #237 (founder 2026-11-17): "the app asks for speech recognition right at
//  the first launch — very bad UX, and it is not clear what it is for." The
//  system prompt now appears only when the player turns voice commands on
//  (onboarding or the listen bar's "Turn on").
//
//  Why these tests matter:
//  - Launch and every listening window READ the permission; a prompt from one
//    of them is the exact bug the founder reported (spy count must stay 0).
//  - "Never asked" and "refused" are different promises on screen ("Turn on"
//    vs "Settings"); collapsing them strands a denied player on a button that
//    can do nothing.
//  - A slow model download must say "Preparing…" while the quiz goes on, and
//    a second tap must not start a second download.
//  - Answers must not depend on the permission: the listener runs answer-only
//    without it (the answer audio and the end-of-speech detection come from
//    the mic tap, not the recognizer).
//  - Turning commands on mid-quiz must work on the same question: the live
//    listener was started without a transcriber and has to be rebuilt.
//

import AVFAudio
import ConcurrencyExtras
import Foundation
@testable import Hangs
import Speech
import Testing

// MARK: - Fakes

/// Counts how often the prompting provider ran — the system alert's one door.
@MainActor
private final class PromptSpy {
    private(set) var prompts = 0
    var answer: SFSpeechRecognizerAuthorizationStatus = .authorized
    /// What `authorizationStatus()` reports; a granted prompt updates it, as iOS does.
    var status: SFSpeechRecognizerAuthorizationStatus

    init(status: SFSpeechRecognizerAuthorizationStatus) {
        self.status = status
    }

    func prompt() -> SFSpeechRecognizerAuthorizationStatus {
        prompts += 1
        status = answer
        return answer
    }
}

/// An engine whose model install can be held, so "Preparing commands…" is
/// observable without waiting on a real download.
@MainActor
private final class HeldAssetsAdapter: CommandTranscriberAdapter {
    // Matches `.speechEnglish`, so a window start keeps this adapter.
    nonisolated let engineTag = "speech"
    nonisolated let locale = Locale(identifier: "en_US")
    var contextualStrings: [String]? { nil }

    var installed = false
    var holdsInstall = false
    private(set) var installCalls = 0
    private var held: CheckedContinuation<Void, Never>?

    func supportedLocales() async -> [Locale] { [locale] }
    func installedLocales() async -> [Locale] { installed ? [locale] : [] }

    func installAssets() async throws {
        installCalls += 1
        if holdsInstall { await withCheckedContinuation { held = $0 } }
        installed = true
    }

    func releaseInstall() {
        held?.resume()
        held = nil
    }

    func makeSession() -> CommandTranscriberSession {
        SpeechTranscriberCommandAdapter(locale: locale).makeSession()
    }
}

@MainActor
private func makeService(
    _ spy: PromptSpy, engine: HeldAssetsAdapter = HeldAssetsAdapter()
) -> SilenceDetectionService {
    SilenceDetectionService(
        authorizationProvider: { await MainActor.run { spy.prompt() } },
        authorizationStatusProvider: { MainActor.assumeIsolated { spy.status } },
        engine: engine
    )
}

// MARK: - Service

@Suite("#237 speech recognition only on request — service")
@MainActor
struct CommandPermissionServiceTests {
    @Test("launch with the permission never asked: no prompt, commands wait for the player")
    func launchNeverAsked() async {
        let spy = PromptSpy(status: .notDetermined)
        let service = makeService(spy)

        await service.prepareCommandsIfAuthorized()

        #expect(spy.prompts == 0, "the first-launch alert is the reported bug")
        #expect(service.commandAvailability == .permissionNeeded)
    }

    @Test("launch with the permission refused: no prompt, the Settings state", arguments: [
        SFSpeechRecognizerAuthorizationStatus.denied, .restricted,
    ])
    func launchRefused(status: SFSpeechRecognizerAuthorizationStatus) async {
        let spy = PromptSpy(status: status)
        let service = makeService(spy)

        await service.prepareCommandsIfAuthorized()

        #expect(spy.prompts == 0)
        #expect(service.commandAvailability == .permissionDenied)
    }

    @Test("launch with the permission given earlier prepares the model silently, as before")
    func launchAuthorizedPreparesAssets() async {
        let spy = PromptSpy(status: .authorized)
        let engine = HeldAssetsAdapter()
        let service = makeService(spy, engine: engine)

        await service.prepareCommandsIfAuthorized()

        #expect(spy.prompts == 0)
        #expect(engine.installCalls == 1)
        #expect(service.commandAvailability == .ready)
    }

    @Test("a quiz-language switch never prompts")
    func languageSwitchNeverPrompts() async {
        let spy = PromptSpy(status: .notDetermined)
        let service = makeService(spy)

        await service.setCommandEngine(.dictationSlovak)

        #expect(spy.prompts == 0)
        #expect(service.transcriberEngine.locale.identifier == "sk_SK")
        #expect(service.commandAvailability == .permissionNeeded)
    }

    @Test("allowed later in iOS Settings: the next window start picks it up without a prompt")
    func windowStartRereadsThePermission() async {
        let spy = PromptSpy(status: .denied)
        let engine = HeldAssetsAdapter()
        engine.installed = true
        let service = makeService(spy, engine: engine)
        await service.prepareCommandsIfAuthorized()
        #expect(service.commandAvailability == .permissionDenied)

        spy.status = .authorized
        await service.setCommandEngine(.speechEnglish) // every window start calls this

        #expect(spy.prompts == 0)
        #expect(service.commandAvailability == .ready)
    }

    @Test("Turn on: one prompt, granted prepares the model")
    func enableGranted() async {
        let spy = PromptSpy(status: .notDetermined)
        let engine = HeldAssetsAdapter()
        let service = makeService(spy, engine: engine)
        await service.prepareCommandsIfAuthorized()

        let granted = await service.enableCommands()

        #expect(granted)
        #expect(spy.prompts == 1)
        await pumpUntil({ service.commandAvailability == .ready }, "the model was never prepared")
        #expect(engine.installCalls == 1)
    }

    @Test("Turn on: refused lands on the Settings state, never back on Turn on")
    func enableRefused() async {
        let spy = PromptSpy(status: .notDetermined)
        spy.answer = .denied
        let service = makeService(spy)
        await service.prepareCommandsIfAuthorized()

        let granted = await service.enableCommands()

        #expect(!granted)
        #expect(spy.prompts == 1)
        #expect(service.commandAvailability == .permissionDenied)
    }

    @Test("Turn on after a refusal does not prompt again (iOS would not show it)")
    func enableAfterRefusalDoesNotPrompt() async {
        let spy = PromptSpy(status: .denied)
        let service = makeService(spy)

        let granted = await service.enableCommands()

        #expect(!granted)
        #expect(spy.prompts == 0)
        #expect(service.commandAvailability == .permissionDenied)
    }

    @Test("a slow model download shows Preparing, returns at once, and is never started twice")
    func slowInstallShowsPreparing() async {
        let spy = PromptSpy(status: .notDetermined)
        let engine = HeldAssetsAdapter()
        engine.holdsInstall = true
        let service = makeService(spy, engine: engine)
        await service.prepareCommandsIfAuthorized()

        // Returns while the download is still held: the onboarding and the
        // quiz never wait on it.
        #expect(await service.enableCommands())
        await pumpUntil({ service.commandAvailability == .installingAssets }, "no Preparing state")
        #expect(await service.enableCommands(), "a second tap while it downloads")
        #expect(engine.installCalls == 1, "one download, however often the player taps")

        engine.releaseInstall()
        await pumpUntil({ service.commandAvailability == .ready }, "the held download never finished")
    }

    @Test("a failed listening window never hides the player's Turn on / Settings button", arguments: [
        VoiceCommandAvailability.permissionNeeded, .permissionDenied,
    ])
    func windowFailureKeepsPermissionState(state: VoiceCommandAvailability) {
        let service = makeService(PromptSpy(status: .notDetermined))
        service.commandAvailability = state

        service.markCommandsUnavailable(reason: "Command listener: invalid input format")

        #expect(service.commandAvailability == state)
    }

    // The engine itself cannot run headlessly (SharedEngineTests); these pin
    // the rule `startListening` applies at its top.
    @Test("without the permission a listening window is answer-only — no recognizer", arguments: [
        SFSpeechRecognizerAuthorizationStatus.notDetermined, .denied, .restricted,
    ])
    func answerOnlyWithoutPermission(status: SFSpeechRecognizerAuthorizationStatus) {
        #expect(!SilenceDetectionService.runsCommandTranscriber(status))
    }

    @Test("with the permission the window builds the recognizer, as before")
    func transcriberWithPermission() {
        #expect(SilenceDetectionService.runsCommandTranscriber(.authorized))
    }

    @Test("the answer-only format is the 16 kHz mono 16-bit the answer upload and the neural VAD expect")
    func answerOnlyFormat() {
        let format = SilenceDetectionService.answerOnlyFormat
        #expect(format.sampleRate == 16000)
        #expect(format.channelCount == 1)
        #expect(format.commonFormat == .pcmFormatInt16)
        #expect(format.sampleRate == SileroVAD.sampleRate)
    }
}

// MARK: - Listen bar control

@Suite("#237 listen bar commands control")
@MainActor
struct CommandsBarAccessoryTests {
    private let availabilities: [VoiceCommandAvailability] = [
        .unknown, .permissionNeeded, .permissionDenied, .installingAssets, .ready, .unavailable(reason: "x"),
    ]

    @Test("every availability × switch × mic combination")
    func mapping() {
        for availability in availabilities {
            for enabled in [true, false] {
                for hints in [true, false] {
                    for micDenied in [true, false] {
                        for hasCommands in [true, false] {
                            let result = VoiceCommandCoordinator.commandsBarAccessory(
                                availability: availability, voiceCommandsEnabled: enabled,
                                showsHints: hints, micDenied: micDenied, phaseHasCommands: hasCommands
                            )
                            let expected: ListenBar.CommandsAccessory? = if enabled, hints, !micDenied, hasCommands {
                                switch availability {
                                case .permissionNeeded: .turnOn
                                case .installingAssets: .preparing
                                case .permissionDenied: .openSettings
                                default: nil
                                }
                            } else {
                                nil
                            }
                            #expect(result == expected, "\(availability) enabled=\(enabled) hints=\(hints) micDenied=\(micDenied) commands=\(hasCommands)")
                        }
                    }
                }
            }
        }
    }

    @Test("the question screen offers it only where command words would be")
    func perPhase() async {
        let (vm, silence, audio) = makePermissionVM(availability: .permissionNeeded)

        #expect(vm.commandsAccessory(for: .readingQuestion) == .turnOn)
        #expect(vm.commandsAccessory(for: .thinking(remaining: 20, total: 30)) == .turnOn)
        #expect(vm.commandsAccessory(for: .listening(.open)) == nil, "the mic is open for the answer")
        #expect(vm.commandsAccessory(for: .evaluating) == nil)

        vm.settings.voiceHintsEnabled = false
        #expect(vm.commandsAccessory(for: .readingQuestion) == nil, "hidden hints hide the button too")
        vm.settings.voiceHintsEnabled = true

        audio.micPermissionStatus = .denied
        #expect(vm.commandsAccessory(for: .readingQuestion) == nil, "commands need the mic")
        audio.micPermissionStatus = .granted

        silence.commandAvailability = .permissionDenied
        await pumpUntil { vm.commandAvailability == .permissionDenied }
        #expect(vm.commandsAccessory(for: .readingQuestion) == .openSettings)
    }
}

// MARK: - Turning commands on mid-quiz

@Suite("#237 turning commands on from the listen bar")
@MainActor
struct TurnOnCommandsMidQuizTests {
    @Test("the live listener is rebuilt once commands are ready, so they work on this question")
    func rearmsTheWindow() async {
        let (vm, silence, _) = makePermissionVM(availability: .permissionNeeded)
        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()
        #expect(silence.isListening)
        let stops = silence.stopListeningCallCount
        let starts = silence.startListeningCallCount

        await vm.enableVoiceCommands(source: .listenBar)

        await pumpUntil({ silence.startListeningCallCount > starts }, "the listener was never rebuilt")
        #expect(silence.stopListeningCallCount > stops, "the answer-only engine must go first")
        #expect(silence.isListening)
        #expect(vm.commandListenerHint != nil, "commands are live on the same question")
        #expect(!vm.voiceCommandCoordinator.rearmsListenerWhenCommandsReady, "one rebuild, not a loop")
    }

    @Test("a refusal rebuilds nothing and reports it")
    func refusalLeavesTheListener() async {
        let analytics = MockAnalyticsClient()
        let (vm, silence, _) = makePermissionVM(availability: .permissionNeeded, analytics: analytics)
        silence.enableCommandsGrants = false
        vm.quizState = .askingQuestion
        await vm.audioDeviceState.startSilenceDetectionListening()
        let stops = silence.stopListeningCallCount

        let granted = await vm.enableVoiceCommands(source: .listenBar)

        #expect(!granted)
        await pumpUntil { vm.commandAvailability == .permissionDenied }
        #expect(silence.stopListeningCallCount == stops)
        #expect(!vm.voiceCommandCoordinator.rearmsListenerWhenCommandsReady)
        #expect(analytics.events.contains(.voiceCommandsTurnedOn(source: .listenBar, result: .denied)))
    }

    @Test("the quiz holds still under the system prompt and continues after it")
    func pausesUnderThePrompt() async {
        let analytics = MockAnalyticsClient()
        let (vm, silence, _) = makePermissionVM(availability: .permissionNeeded, analytics: analytics)
        vm.quizState = .askingQuestion
        let pausedDuringPrompt = LockIsolated(false)
        silence.onEnableCommands = { @MainActor in
            let paused = vm.isPaused
            pausedDuringPrompt.setValue(paused)
        }

        await vm.turnOnVoiceCommandsFromListenBar()

        #expect(silence.enableCommandsCallCount == 1)
        #expect(pausedDuringPrompt.value, "the read and the think window must not run out behind the alert")
        #expect(!vm.isPaused)
        #expect(analytics.events.contains(.voiceCommandsTurnedOn(source: .listenBar, result: .granted)))
    }
}

// MARK: - Helpers

@MainActor
private func makePermissionVM(
    availability: VoiceCommandAvailability,
    analytics: AnalyticsClient = NoopAnalyticsClient()
) -> (QuizViewModel, MockSilenceDetectionService, MockAudioService) {
    let silence = MockSilenceDetectionService()
    silence.commandAvailability = availability
    let audio = MockAudioService()
    let vm = QuizViewModel(
        networkService: Fixtures.makeFullMockNetwork(),
        audioService: audio,
        persistenceStore: MockPersistenceStore(),
        silenceDetectionService: silence,
        analytics: analytics
    )
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = Fixtures.makeQuestion()
    return (vm, silence, audio)
}
