//
//  RoundEndVoiceTests.swift
//  HangsTests
//
//  #243 decision 5 (founder 2026-11-24): every round end (score, recap,
//  daily challenge) says its line, listens, and on silence asks once more,
//  then waits. Was #188 G3 (score screen only, "znova" only) in
//  QuizEndVoiceTests. #248 (founder 2026-11-25): the line is "Hotovo. Máš
//  správne 7 z 10 odpovedí. [Za odmenu …] Chceš hrať ďalší kvíz? Povedz:
//  ďalší. Alebo otvoriť úvodnú obrazovku? Povedz: domov." and "ďalší"
//  replaces "znova".
//

import Clocks
import Foundation
@testable import Hangs
import Testing

@MainActor
private func drain() async {
    for _ in 0 ..< 30 {
        await Task.yield()
    }
}

@Suite("#243 decision 5, #248 — the round end offers 'ďalší' or 'domov'")
@MainActor
struct RoundEndVoiceTests {
    private struct Rig {
        let vm: QuizViewModel
        let silence: MockSilenceDetectionService
        let network: MockNetworkService
        let audio: MockAudioService
        let clock: TestClock<Duration>
        let analytics: MockAnalyticsClient

        var language: CommandLanguage {
            .forQuizLanguage(vm.currentSession?.language ?? vm.settings.language)
        }
    }

    private func makeRig() -> Rig {
        let silence = MockSilenceDetectionService()
        let audio = MockAudioService()
        audio.playbackDurationNs = 0
        let network = Fixtures.makeFullMockNetwork()
        let clock = TestClock()
        network.networkClock = AnyClock(clock)
        let analytics = MockAnalyticsClient()
        let vm = QuizViewModel(
            networkService: network,
            audioService: audio,
            persistenceStore: MockPersistenceStore(),
            silenceDetectionService: silence,
            clock: AnyClock(clock),
            analytics: analytics
        )
        vm.currentSession = Fixtures.makeActiveSession()
        vm.currentQuestion = Fixtures.makeQuestion(id: "q_001")
        vm.quizState = .processing
        return Rig(vm: vm, silence: silence, network: network, audio: audio, clock: clock, analytics: analytics)
    }

    /// The round end's line with the words it really listens for.
    private func roundEndLine(_ rig: Rig, correct: Int = 7, bonus: Int? = nil) -> String {
        SpokenPrompt.setFinishedLine(
            correct: correct, total: 10, bonusQuestions: bonus,
            commands: VoiceCommandLexicon.commands(on: .setEnd), language: rig.language
        )
    }

    /// The word the round end offers for the next quiz („ďalší“).
    private func nextWord(_ rig: Rig) -> String {
        VoiceCommandLexicon.spokenWord(.next, language: rig.language, on: .setEnd)
    }

    private func roundEndQuestion(_ rig: Rig) -> String? {
        SpokenPrompt.setEndQuestion(commands: VoiceCommandLexicon.commands(on: .setEnd), language: rig.language)
    }

    /// The set ends (server says so) and the round end comes up listening.
    private func finishRound(_ rig: Rig, correct: Int = 7) async {
        rig.vm.sessionCorrectCount = correct
        await rig.vm.handleError(NetworkError.sessionFinished, context: .submission, fallbackMessage: "x")
        #expect(rig.vm.quizState == .finished)
        await listensAtRoundEnd(rig, "the round end never listened")
    }

    private func listensAtRoundEnd(_ rig: Rig, _ comment: Comment) async {
        await pumpUntil({ rig.silence.isListening && rig.vm.voiceCommandCoordinator.currentCommandScreen == .setEnd }, comment)
        // Lets the re-ask wait start on the test clock before a test moves it.
        await drain()
    }

    /// WHY (D3, #243 decision 5; #248): the round ended in silence and the
    /// driver never learned the score, nor what they could say next. The line
    /// says both, the music gets its volume back, and the screen listens on
    /// the quiet session like Home. "Ďalší" starts the next quiz, as the
    /// founder asked (2026-11-25), not "znova".
    @Test("the round end says the score and its offer, then 'next' starts the next quiz")
    func setEndSpeaksScoreAndListens() async {
        let rig = makeRig()
        await finishRound(rig)

        #expect(rig.network.synthesizedTexts == [roundEndLine(rig)])
        #expect(rig.audio.deactivateSessionCallCount >= 1, "the quiz session was released")
        #expect(rig.audio.setupQuietListeningSessionCallCount >= 1, "listening must not duck the music")

        var recognized: [VoiceCommand] = []
        rig.vm.voiceCommandCoordinator.onCommandRecognized = { recognized.append($0) }
        rig.silence.simulateCommandTranscript(nextWord(rig))
        await pumpUntil({ recognized == [.next] }, "'next' did not act at the round end")
        await pumpUntil({ rig.network.createSessionCallCount == 1 }, "'next' did not start a quiz")
    }

    /// WHY (#248, founder 2026-11-25): "znova" after a daily challenge made
    /// no sense, so the round end no longer takes it; a passenger's "again"
    /// must not start a quiz.
    @Test("'again' no longer acts at the round end")
    func againIsInert() async {
        let rig = makeRig()
        await finishRound(rig)
        rig.silence.simulateCommandTranscript(VoiceCommandLexicon.spokenWord(.again, language: rig.language))
        await drain()
        #expect(rig.vm.quizState == .finished)
        #expect(rig.network.createSessionCallCount == 0)
    }

    /// WHY (#243 decision 5): "domov" is the second word the line names; it
    /// must do exactly what the Home button does, and the analytics must see
    /// it, or there is no telling whether players use it.
    @Test("'home' at the round end goes Home, like the Home button, and is reported")
    func homeGoesHome() async {
        let rig = makeRig()
        await finishRound(rig)

        rig.silence.simulateCommandTranscript(VoiceCommandLexicon.spokenWord(.home, language: rig.language))
        await pumpUntil({ rig.vm.quizState == .idle }, "'home' did not leave the round end")
        let event = rig.analytics.events.first { $0.name == "voice_command" }
        #expect(event?.properties["command"] == .string("home"))
        #expect(event?.properties["phase"] == .string("setEnd"))
    }

    /// WHY (founder decision 5: "pri tichu sa raz spýta, potom čaká"): a
    /// driver who missed the line hears the question once more; asking again
    /// and again would nag, so after that the screen waits without a word.
    @Test("silence at the round end asks once more, then waits silently with the commands still armed")
    func silenceAsksOnceMore() async throws {
        let rig = makeRig()
        await finishRound(rig)
        let question = try #require(roundEndQuestion(rig))

        await rig.clock.advance(by: QuizViewModel.roundEndReaskDelay - .milliseconds(1))
        await drain()
        #expect(rig.network.synthesizedTexts == [roundEndLine(rig)], "asked again before the silence ran out")

        await rig.clock.advance(by: .milliseconds(1))
        await pumpUntil({ rig.network.synthesizedTexts == [roundEndLine(rig), question] }, "silence was never answered")
        await pumpUntil({ rig.audio.playOpusCallCount == 2 }, "the question was not said")
        await listensAtRoundEnd(rig, "the re-ask left the round end deaf")

        await rig.clock.advance(by: .seconds(120))
        await drain()
        #expect(rig.network.synthesizedTexts.count == 2, "the round end asked more than once")
        #expect(rig.audio.playOpusCallCount == 2)

        rig.silence.simulateCommandTranscript(VoiceCommandLexicon.spokenWord(.home, language: rig.language))
        await pumpUntil({ rig.vm.quizState == .idle }, "'home' did not work after the re-ask")
    }

    /// WHY: the question is for a driver who heard nothing; one who spoke
    /// (a passenger, a word the app did not take) was heard, so the screen
    /// does not talk over them.
    @Test("speech heard at the round end means no re-ask")
    func speechMeansNoReask() async {
        let rig = makeRig()
        await finishRound(rig)

        rig.silence.simulateCommandTranscript("lunch")
        await drain()
        await rig.clock.advance(by: QuizViewModel.roundEndReaskDelay + .seconds(60))
        await drain()
        #expect(rig.network.synthesizedTexts == [roundEndLine(rig)])
        #expect(rig.vm.quizState == .finished)
    }

    /// WHY (#235 beyond the happy path): the line comes from the server. With
    /// the network gone the screen must still listen and both words must
    /// still work; a failed re-ask must not leave it deaf either.
    @Test("the line cannot be fetched → the round end still listens, after the failed re-ask too")
    func failedLineStillListens() async {
        let rig = makeRig()
        rig.network.setNetworkCondition(.offline, for: [.synthesizeSpeech])
        await finishRound(rig)
        #expect(rig.audio.playOpusCallCount == 0)

        await rig.clock.advance(by: QuizViewModel.roundEndReaskDelay)
        await pumpUntil({ rig.network.synthesizedTexts.count == 2 }, "no re-ask was tried")
        await listensAtRoundEnd(rig, "the failed re-ask left the round end deaf")
        #expect(rig.audio.playOpusCallCount == 0)

        rig.silence.simulateCommandTranscript(nextWord(rig))
        await pumpUntil({ rig.vm.quizState != .finished }, "'next' did not work without the line")
    }

    /// WHY (#235): a slow server must not hold the round end silent and deaf.
    /// Past the prompt bound the line is skipped and the screen listens; the
    /// audio that arrives late is never played into the open mic.
    @Test("a slow line is skipped after the prompt bound; the screen listens and late audio stays silent")
    func slowLineIsSkipped() async {
        let rig = makeRig()
        let hold = rig.network.hold(.synthesizeSpeech)
        rig.vm.sessionCorrectCount = 7
        await rig.vm.handleError(NetworkError.sessionFinished, context: .submission, fallbackMessage: "x")
        await pumpUntil({ hold.heldCount == 1 }, "the line never reached the server")
        #expect(!rig.silence.isListening, "listening before the line was said")

        await rig.clock.advance(by: .seconds(QuizViewModel.promptFetchTimeoutSeconds))
        await listensAtRoundEnd(rig, "the slow line held the round end deaf")
        hold.release()
        await drain()
        #expect(rig.audio.playOpusCallCount == 0, "late audio played into the open mic")
    }

    /// WHY (#243 decision 5): the recap is a round end too. Muted or set not
    /// to read itself, it says the line at once and listens.
    @Test("a recap that does not read itself says the line and listens")
    func recapWithoutReadSpeaksAndListens() async {
        let (vm, network) = await finishOnRecap(autoReads: false)
        await pumpUntil({ vm.voiceCommandCoordinator.currentCommandScreen == .setEnd }, "the recap never listened")
        #expect(network.synthesizedTexts == [Self.recapLine(vm)])
    }

    /// WHY: the recap reads its summary first; the line on top would talk over
    /// it, and the read must not reach a live mic. So the line follows the
    /// read, and only then does the screen listen.
    @Test("the recap reads its summary, then says the line, then listens")
    func recapReadsThenSpeaks() async {
        let (vm, network) = await finishOnRecap(autoReads: true)
        await drain()
        #expect(network.synthesizedTexts.isEmpty, "the line came before the recap's read")
        #expect(vm.voiceCommandCoordinator.currentCommandScreen == nil)

        vm.autoPlayRecapIfHandsFree() // SetRecapView.onAppear
        await pumpUntil({ vm.voiceCommandCoordinator.currentCommandScreen == .setEnd }, "the recap never listened")
        let chunks = vm.recapNarrationChunks()
        #expect(network.synthesizedTexts == chunks + [Self.recapLine(vm)])
    }

    /// The recap's round end, with the voice line it should say.
    private static func recapLine(_ vm: QuizViewModel) -> String {
        SpokenPrompt.setFinishedLine(
            correct: vm.sessionCorrectCount,
            total: vm.currentSession?.maxQuestions ?? vm.settings.numberOfQuestions,
            commands: VoiceCommandLexicon.commands(on: .setEnd),
            language: .forQuizLanguage(vm.currentSession?.language ?? vm.settings.language)
        )
    }

    private func finishOnRecap(autoReads: Bool) async -> (QuizViewModel, MockNetworkService) {
        let (vm, network) = Fixtures.makeViewModelWithNetwork(clock: AnyClock(TestClock()))
        (vm.audioService as? MockAudioService)?.playbackDurationNs = 0
        vm.settings.answerRevealMode = .endOfSet
        vm.autoReadsRecap = autoReads
        vm.currentSession = Fixtures.makeQuizSession()
        vm.currentQuestion = Fixtures.makeQuestion()
        vm.quizState = .processing

        await vm.handleQuizResponse(QuizResponse(
            success: true,
            message: "Input processed",
            session: Fixtures.makeQuizSession(phase: "finished"),
            currentQuestion: nil,
            evaluation: Evaluation(
                userAnswer: "a", result: .correct, points: 1, correctAnswer: "a",
                questionId: "q_001", explanation: nil, headlineAnswer: nil
            ),
            feedbackReceived: [],
            audio: nil
        ))
        // The deferred advance runs on real sleeps (#180 track A).
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while vm.quizState != .finished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(vm.quizState == .finished)
        #expect(vm.endsOnRecap)
        return (vm, network)
    }

    /// WHY (#243 decision 5): the daily challenge end used to say nothing.
    /// It says the line too; with no replay there (one challenge a day),
    /// "ďalší" starts an ordinary round rather than the played day again.
    @Test("the daily challenge end says the line; 'next' starts an ordinary round")
    func dailyEndSpeaksAndNextStartsARound() async {
        let rig = makeRig()
        rig.vm.activeDaily = DailyRound(day: DailyChallengeDay(.now), language: rig.vm.settings.language)
        await finishRound(rig, correct: 3)
        #expect(rig.network.synthesizedTexts == [roundEndLine(rig, correct: 3)])

        rig.silence.simulateCommandTranscript(nextWord(rig))
        await pumpUntil({ rig.network.createSessionCallCount == 1 }, "'next' did not start a round")
        #expect(rig.network.startDailyChallengeCallCount == 0, "'next' replayed the daily challenge")
    }

    /// A finished daily challenge as the server reports it, with `left` extra
    /// questions for today.
    private static func finishedDaily(left: Int?) -> DailyChallengeState {
        DailyChallengeState(
            date: DailyChallengeDay(.now).isoDate, language: "en", status: .played, total: 5,
            summary: DailySummary(
                score: 3, total: 5, marks: [true, true, false, true, false], players: 2,
                comparison: nil, rank: nil, bestHit: nil
            ),
            bonusOffer: 10, bonusLeft: left
        )
    }

    /// WHY (#248, founder 2026-11-25): the reward is the reason to play the
    /// daily challenge, so its end says it: "Za odmenu máš dnes 10 otázok
    /// navyše." The number is the one the screen shows (the finished state).
    @Test("a daily challenge that earned extra questions says how many")
    func dailyEndSaysTheReward() async {
        let rig = makeRig()
        rig.network.stubbedDailyState = Self.finishedDaily(left: 10)
        rig.vm.activeDaily = DailyRound(day: DailyChallengeDay(.now), language: rig.vm.settings.language)
        await finishRound(rig, correct: 3)
        #expect(rig.network.synthesizedTexts == [roundEndLine(rig, correct: 3, bonus: 10)])
    }

    /// WHY: nothing earned (used up, a subscriber) or nothing known (the
    /// fetch failed, #235) means no reward sentence; the score and the offer
    /// still come, and an ordinary round never asks for the daily state.
    @Test("no reward, or no daily state, says the line without it", arguments: [true, false])
    func dailyEndWithoutReward(fetchFails: Bool) async {
        let rig = makeRig()
        if fetchFails {
            rig.network.setNetworkCondition(.offline, for: [.fetchDailyChallenge])
        } else {
            rig.network.stubbedDailyState = Self.finishedDaily(left: 0)
        }
        rig.vm.activeDaily = DailyRound(day: DailyChallengeDay(.now), language: rig.vm.settings.language)
        await finishRound(rig, correct: 3)
        #expect(rig.network.synthesizedTexts == [roundEndLine(rig, correct: 3)])

        let ordinary = makeRig()
        ordinary.network.stubbedDailyState = Self.finishedDaily(left: 10)
        await finishRound(ordinary)
        #expect(ordinary.network.fetchDailyChallengeCallCount == 0)
        #expect(ordinary.network.synthesizedTexts == [roundEndLine(ordinary)])
    }
}

@Suite("#243 decision 5 — round-end words and lines, sk / cs / en / uk")
struct RoundEndWordTests {
    private func match(_ phrase: String, _ screen: VoiceCommandScreen, _ language: CommandLanguage) -> VoiceCommand? {
        VoiceCommandMatcher.match(transcript: phrase, on: screen, isFinal: true, language: language)
    }

    /// WHY (#243 decision 5): the founder's words, per language; the Czech
    /// recognizer may write „domu“ without the ring.
    @Test("the founder's home words act at the round end", arguments: [
        (CommandLanguage.slovak, "domov"), (.czech, "domů"), (.czech, "domu"), (.english, "home"), (.ukrainian, "додому"),
    ])
    func homeWords(_ language: CommandLanguage, _ word: String) {
        #expect(match(word, .setEnd, language) == .home)
        #expect(VoiceCommandMatcher.match(transcript: word, on: .setEnd, isFinal: false, language: language) == .home)
    }

    /// WHY: "home" and "domu" are short, and one letter off them is ordinary
    /// talk; a false fire would take the player off the score screen.
    @Test("a word one letter off a short home word is not home", arguments: [
        (CommandLanguage.english, "come"), (.english, "hole"), (.czech, "dome"),
    ])
    func nearMissesAreNotHome(_ language: CommandLanguage, _ word: String) {
        #expect(match(word, .setEnd, language) == nil)
    }

    /// WHY (#248, founder 2026-11-25): „ďalší“ for the next quiz, plus the
    /// forms people say („ďalšia“, „ďalej“ / „dál“, the button's "ďalší
    /// kvíz"); never only the two words.
    @Test("the next-quiz words act at the round end", arguments: [
        (CommandLanguage.slovak, "ďalší"), (.slovak, "ďalšia"), (.slovak, "ďalej"), (.slovak, "ďalší kvíz"),
        (.czech, "další"), (.czech, "dál"), (.czech, "další kvíz"),
        (.english, "next"), (.english, "next quiz"),
        (.ukrainian, "далі"), (.ukrainian, "наступна"), (.ukrainian, "наступна вікторина"),
    ])
    func nextWords(_ language: CommandLanguage, _ word: String) {
        #expect(match(word, .setEnd, language) == .next)
    }

    /// WHY (#248): the hint and the "I hear" label name the round end's own
    /// word („ďalší“), not the question's „ďalšia“ the player did not say.
    @Test("the round end's hint and captions name its words")
    func displayWords() {
        #expect(VoiceCommandLexicon.hint(on: .setEnd, language: .slovak) == "Povedz „ďalší“ alebo „domov“")
        #expect(VoiceCommandLexicon.hint(on: .setEnd, language: .czech) == "Řekni „další“ nebo „domů“")
        #expect(VoiceCommandLexicon.hint(on: .setEnd, language: .english) == #"Say "next" or "home""#)
        #expect(VoiceCommandLexicon.heardCaption(.next, language: .slovak, on: .setEnd) == "počujem: „ďalší“")
        #expect(VoiceCommandLexicon.recognizingCaption(.next, language: .slovak, on: .setEnd) == "„ďalší“…")
        #expect(VoiceCommandLexicon.heardCaption(.next, language: .slovak, on: .question) == "počujem: „ďalšia“")
    }

    /// WHY: "znova" is retired here, and the question's skip words would
    /// start a whole quiz by surprise.
    @Test("again and skip words do nothing at the round end", arguments: [
        (CommandLanguage.slovak, "znova"), (.slovak, "preskoč"), (.czech, "znovu"), (.czech, "přeskoč"),
        (.english, "again"), (.english, "skip"), (.ukrainian, "ще раз"), (.ukrainian, "пропусти"),
    ])
    func retiredWords(_ language: CommandLanguage, _ word: String) {
        #expect(match(word, .setEnd, language) == nil)
    }

    /// WHY (#248, founder 2026-11-25): the founder's exact round-end lines.
    /// The re-ask on silence is the offer alone.
    @Test("the round-end line in every language", arguments: [
        (
            CommandLanguage.slovak,
            "Hotovo. Máš správne 7 z 10 odpovedí.",
            "Chceš hrať ďalší kvíz? Povedz: ďalší. Alebo otvoriť úvodnú obrazovku? Povedz: domov."
        ),
        (
            .czech,
            "Hotovo. Máš správně 7 z 10 odpovědí.",
            "Chceš hrát další kvíz? Řekni: další. Nebo otevřít úvodní obrazovku? Řekni: domů."
        ),
        (
            .english,
            "Done. You got 7 out of 10 right.",
            "Want to play another quiz? Say: next. Or go to the home screen? Say: home."
        ),
        (
            .ukrainian,
            "Готово. У тебе правильно 7 з 10 відповідей.",
            "Хочеш зіграти ще одну вікторину? Скажи: далі. Або відкрити головний екран? Скажи: додому."
        ),
    ])
    func roundEndLines(_ language: CommandLanguage, _ score: String, _ offer: String) {
        let commands = VoiceCommandLexicon.commands(on: .setEnd)
        #expect(SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: commands, language: language)
            == score + " " + offer)
        #expect(SpokenPrompt.setEndQuestion(commands: commands, language: language) == offer)
        // Nothing listens (commands off): the score alone, and no re-ask.
        #expect(SpokenPrompt.setFinishedLine(correct: 7, total: 10, commands: [], language: language) == score)
        #expect(SpokenPrompt.setEndQuestion(commands: [], language: language) == nil)
    }

    /// WHY (#248): the reward sentence sits between the score and the offer,
    /// and its noun agrees with the number (1 / 2–4 / 5+).
    @Test("the reward sentence, with the right plural", arguments: [
        (CommandLanguage.slovak, 10, "Za odmenu máš dnes 10 otázok navyše."),
        (.slovak, 3, "Za odmenu máš dnes 3 otázky navyše."),
        (.slovak, 1, "Za odmenu máš dnes 1 otázku navyše."),
        (.czech, 10, "Za odměnu máš dnes 10 otázek navíc."),
        (.czech, 2, "Za odměnu máš dnes 2 otázky navíc."),
        (.english, 10, "As a reward you get 10 extra questions today."),
        (.english, 1, "As a reward you get 1 extra question today."),
        (.ukrainian, 10, "У нагороду маєш сьогодні 10 додаткових питань."),
        (.ukrainian, 3, "У нагороду маєш сьогодні 3 додаткові питання."),
        (.ukrainian, 21, "У нагороду маєш сьогодні 21 додаткове питання."),
    ])
    func rewardSentence(_ language: CommandLanguage, _ count: Int, _ sentence: String) {
        let commands = VoiceCommandLexicon.commands(on: .setEnd)
        let line = SpokenPrompt.setFinishedLine(
            correct: 1, total: 5, bonusQuestions: count, commands: commands, language: language
        )
        let score = SpokenPrompt.setFinishedLine(correct: 1, total: 5, commands: [], language: language)
        let offer = SpokenPrompt.setEndQuestion(commands: commands, language: language) ?? ""
        #expect(line == [score, sentence, offer].joined(separator: " "))
        #expect(SpokenPrompt.setFinishedLine(correct: 1, total: 5, bonusQuestions: 0, commands: commands, language: language)
            == score + " " + offer)
    }
}
