//
//  QuizToolbarHeaderTests.swift
//  HangsTests
//
//  #173 Tracks B + D — the quiz chrome the founder locked on 2026-09-07.
//
//  What each suite is defending, in the founder's own field terms:
//   - Toolbar: "kategória sa prekrýva s tlačidlami" — MCQ and voice each drew
//     their own top row and the TestFlight chips were an absolute overlay on
//     top of one of them. One native toolbar, present in every mode and state,
//     carrying controls that behave the same wherever they are drawn.
//   - Progress: "progress bar = poradie otázky". The bar was 0-based while the
//     counter was 1-based, so question 1 showed nothing and question 10 never
//     filled. Question N lights N segments — both ends of the set pinned.
//   - Pause: it used to exist only on the confirmation sheet. It has to freeze
//     a running think window and an open mic, and resume has to hand back a
//     FULL window (a pause that shortens the clock is not a pause).
//   - Evaluating: the sheet stays up with its own button spinning, and every
//     other control on it goes dead — a live Re-record over an in-flight
//     submission is the race #133 V14 already had to fix once.
//
//  Split of altitude: the toolbar's PRESENCE is asserted on QuestionView, its
//  CONTENTS on the control components — see `QuizToolbarInspection` for why.
//

import Foundation
@testable import Hangs
import SwiftUI
import Testing
import ViewInspector

@MainActor
private func makeQuestionViewModel(question: Question, state: QuizState = .askingQuestion) -> QuizViewModel {
    let vm = Fixtures.makeViewModel()
    vm.currentSession = Fixtures.makeActiveSession()
    vm.currentQuestion = question
    vm.quizState = state
    return vm
}

// MARK: - Toolbar controls

@MainActor
@Suite("Quiz toolbar — one header for every question type (#173 A3)")
struct QuizToolbarTests {
    /// The founder's finding 1b was that the two modes had drifted: MCQ drew its
    /// own merged row with no settings gear, voice drew another. One toolbar on
    /// the shared body is the fix — it must exist in BOTH modes and, per founder
    /// decision 1, in every quiz state including evaluating.
    @Test("the quiz screen owns a toolbar in both modes and in every state",
          arguments: [Question.previewMCQ, Question.preview])
    func toolbarPresentInBothModes(question: Question) async throws {
        for state in [QuizState.askingQuestion, .recording, .processing] {
            let vm = makeQuestionViewModel(question: question, state: state)
            let view = QuestionView(viewModel: vm)
            try await ViewHosting.host(view) {
                #expect(QuizToolbarInspection.hasToolbar(view),
                        "no toolbar in \(state) for \(question.isMultipleChoice ? "MCQ" : "voice")")
            }
        }
    }

    /// Founder batch 2026-07-12: the chrome must render the moment the quiz
    /// starts, before the first question payload lands — a bar that appears late
    /// reads as an empty screen.
    @Test("the toolbar renders in .startingQuiz, before any question exists")
    func toolbarRendersWhileStarting() async throws {
        let vm = Fixtures.makeViewModel()
        vm.quizState = .startingQuiz
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            #expect(QuizToolbarInspection.hasToolbar(view))
        }
    }

    /// #173 finding 1a: a mute carried over from a previous run silenced the
    /// first question and the driver could not see why. The glyph has to SAY
    /// muted — same speaker family, but slashed and pink, not a silent no-op.
    @Test("the mute glyph names the state it is in", arguments: [true, false])
    func muteGlyphNamesTheState(isMuted: Bool) async throws {
        let view = QuizMuteToolbarButton(isMuted: isMuted) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let glyph = try tree.find(ViewType.Image.self).actualImage().name()
            #expect(glyph == (isMuted ? "speaker.slash.fill" : "speaker.wave.2"))
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.mute")
            }
        }
    }

    /// The pause control is a TOGGLE, not a one-way door: a driver who paused at
    /// a junction has to see the way back, and the glyph is the whole signal.
    @Test("the pause glyph flips to play once paused", arguments: [true, false])
    func pauseGlyphFlips(isPaused: Bool) async throws {
        let view = QuizPauseToolbarButton(isPaused: isPaused) {}
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let glyph = try tree.find(ViewType.Image.self).actualImage().name()
            #expect(glyph == (isPaused ? "play.fill" : "pause.fill"))
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.pause")
            }
        }
    }

    /// Settings had left the MCQ screen entirely in #125 (reachable only through
    /// the End Quiz alert). Under ⋯ it is back for every mode — and the two
    /// TestFlight rows keep their #155 gate, so an App Store build shows one row.
    @Test("the ⋯ menu always carries Settings; the TestFlight rows follow their gate")
    func overflowMenuGating() async throws {
        let gated = QuizOverflowMenu(onSettings: {}, onFeedback: {}, onRateQuestion: {})
        try await ViewHosting.host(gated) {
            let tree = try gated.inspect()
            for id in ["question.settingsButton", "feedback.entry", "rating.entry"] {
                #expect(throws: Never.self, "\(id) missing from the ⋯ menu") {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
        }

        let appStore = QuizOverflowMenu(onSettings: {})
        try await ViewHosting.host(appStore) {
            let tree = try appStore.inspect()
            #expect(throws: Never.self) {
                try tree.find(viewWithAccessibilityIdentifier: "question.settingsButton")
            }
            for id in ["feedback.entry", "rating.entry"] {
                #expect(throws: (any Error).self, "\(id) must be absent when the gate is closed") {
                    _ = try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
        }
    }

    /// The mute is one source of truth — but #173 Track A (founder decision 4)
    /// made that source `isAudioMuted`, not the persisted flag. The toolbar
    /// button silences the RUNNING quiz (`quizMuteOverride`, cleared at quiz
    /// start) and every TTS guard reads the effective value; `settings.isMuted`
    /// belongs to the Settings "Sound" toggle alone. Sharing one persisted flag
    /// is precisely how finding 1a happened — a mute tapped mid-drive silenced
    /// the first question of the NEXT quiz.
    @Test("tapping the toolbar mute mutes the running quiz, not the persisted preference")
    func toolbarMuteTogglesSetting() async throws {
        let vm = makeQuestionViewModel(question: Question.preview, state: .recording)
        vm.settings.isMuted = false
        let view = QuizMuteToolbarButton(isMuted: vm.isAudioMuted) {
            Task { await vm.toggleMute() }
        }
        try await ViewHosting.host(view) {
            try view.inspect().find(viewWithAccessibilityIdentifier: "question.mute").button().tap()
            // toggleMute() is async (it also stops in-flight TTS), so drain.
            for _ in 0 ..< 50 where !vm.isAudioMuted { await Task.yield() }
            #expect(vm.isAudioMuted == true, "the quiz the driver is in must go quiet")
            #expect(vm.settings.isMuted == false, "…but nothing about the next quiz may change")
        }
    }
}

// MARK: - Segmented progress

@MainActor
@Suite("Quiz progress header — 1-based (#173 finding 1c)")
struct QuizProgressHeaderTests {
    /// The bug in one assertion: the bar read `questionsAnswered / total` while
    /// the counter read `questionsAnswered + 1`. On question 1 of 10 the driver
    /// saw "01 / 10" over an EMPTY bar, and on the last question the bar still
    /// was not full. Both ends are pinned here.
    @Test("question 1 lights exactly one segment and the last question lights them all")
    func segmentFillIsOneBased() {
        let first = HangsSegmentedProgress(current: 1, total: 10)
        #expect(first.isFilled(0), "question 1 must light the first segment")
        #expect(first.isFilled(1) == false, "question 1 must light exactly one")

        let last = HangsSegmentedProgress(current: 10, total: 10)
        #expect((0 ..< 10).allSatisfy { last.isFilled($0) },
                "the last question must fill the whole row — it never did before")
    }

    /// The linear fallback (long sets, where dashes stop being countable) carries
    /// the same 1-based contract, or the bug just moves to sets of 20.
    @Test("the long-set fallback bar is 1-based too")
    func linearFallbackIsOneBased() {
        #expect(HangsQuizProgressHeader.linearProgress(current: 1, total: 20) == 0.05)
        #expect(HangsQuizProgressHeader.linearProgress(current: 20, total: 20) == 1)
        #expect(HangsQuizProgressHeader.linearProgress(current: 1, total: 0) == 0)
    }

    /// One meta row for every question type now — the MCQ "CATEGORY · Qn" row
    /// and the voice `metaRow` were separate surfaces, and only one of them
    /// collided with the TestFlight chips.
    @Test("both modes render the same category + counter + progress row",
          arguments: [Question.previewMCQ, Question.preview])
    func metaRowIsShared(question: Question) async throws {
        let vm = makeQuestionViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            for id in ["question.category", "question.counter", "question.progress"] {
                #expect(throws: Never.self, "\(id) missing from the shared header") {
                    try tree.find(viewWithAccessibilityIdentifier: id)
                }
            }
            // 1-based, in the compact "1/10" form of the A3 mock.
            #expect(throws: Never.self) { try tree.find(text: "1/10") }
        }
    }
}

// MARK: - Quiz-level pause

@MainActor
@Suite("Quiz pause from the toolbar (#173 decision 4)")
struct QuizToolbarPauseTests {
    /// Pause used to be reachable only from the confirmation sheet. The think
    /// window is the state a driver actually wants to stop — a passenger talking,
    /// a junction — and freezing it must also take the mic down, or "paused" is
    /// still listening.
    @Test("pause freezes a running think window and takes the mic down")
    func pauseFromThinkingFreezesTheWindow() {
        let vm = makeQuestionViewModel(question: Question.previewMCQ)
        vm.settings.autoRecordEnabled = false
        vm.settings.answerTimeLimit = 30
        vm.quizTimersController.startAnswerTimer()
        #expect(vm.answerTimerCountdown == 30, "precondition: the window is running")

        vm.togglePause()

        #expect(vm.isPaused)
        #expect(vm.answerTimerCountdown == 0, "a pause that leaves the clock running is not a pause")
        #expect(vm.voiceCommandCoordinator.mayCaptureAudio == false, "the mic comes down with the pause")
    }

    /// Resume hands back a FULL window, never the remainder — the same rule the
    /// confirmation sheet's pause already followed (#171 Track D).
    @Test("resume re-arms the full window")
    func resumeReArmsAFullWindow() {
        let vm = makeQuestionViewModel(question: Question.previewMCQ)
        vm.settings.autoRecordEnabled = false
        vm.settings.answerTimeLimit = 30
        vm.quizTimersController.startAnswerTimer()
        vm.togglePause()
        vm.answerTimerCountdown = 0

        vm.togglePause()

        #expect(vm.isPaused == false)
        #expect(vm.answerTimerCountdown == 30, "resume must re-arm the whole window, not the remainder")
        vm.quizTimersController.cancelAnswerTimer()
    }

    /// An open mic cannot simply be frozen — the stream is not resumable and the
    /// words already spoken would be lost. Pausing routes through the EXISTING
    /// stop/submit funnel instead, so the recording ends and the answer survives.
    @Test("pause during recording ends the recording instead of freezing an open mic")
    func pauseDuringRecordingStopsTheRecording() async {
        let vm = makeQuestionViewModel(question: Question.preview, state: .recording)
        #expect(vm.canPauseQuiz, "recording is a pausable state")

        vm.togglePause()

        #expect(vm.isPaused)
        await pumpUntil({ vm.quizState != .recording },
                        "pause must take the mic down, not leave it open behind a paused UI")
    }

    /// The hole a pause this broad opens: `enterPause()` silences in-flight TTS,
    /// and the question-audio tail that resolves as a result calls straight back
    /// into `startRecordingOrTimer()` — which re-armed the window behind a paused
    /// UI. The guard belongs on the timers themselves (where auto-confirm and
    /// auto-advance already had one), not on each caller that might race.
    @Test("a late re-arm cannot restart the window while the quiz is paused")
    func pausedQuizRefusesToReArm() {
        let vm = makeQuestionViewModel(question: Question.preview)
        vm.settings.autoRecordEnabled = false
        vm.settings.answerTimeLimit = 30
        vm.togglePause()

        // Exactly what the TTS-completion tail calls on the question screen.
        vm.startRecordingOrTimer()
        #expect(vm.answerTimerCountdown == 0, "a paused quiz must not re-arm the answer window")

        vm.settings.autoRecordEnabled = true
        vm.settings.thinkingTime = 5
        vm.startRecordingOrTimer()
        #expect(vm.thinkingTimeCountdown == 0, "…nor the thinking window")
    }

    /// Finding 2 of the #173 review: pausing mid-recording LANDS on the
    /// confirmation sheet, the sheet's own Pause/Continue pill was removed, and
    /// the listener is down while paused — so if the sheet swallowed the
    /// presenter's toolbar, pause would be one-way. The toolbar's control must
    /// stay live there (it is enabled while paused, in any state), and toggling
    /// it must actually resume. Whether the tap LANDS through the sheet is
    /// `presentationBackgroundInteraction`'s job and is checked on the simulator.
    @Test("a pause taken onto the confirmation sheet can be resumed from the toolbar")
    func pausedSheetIsResumable() {
        let vm = makeQuestionViewModel(question: Question.preview, state: .processing)
        vm.settings.autoConfirmEnabled = true
        vm.transcribedAnswer = "Paris"
        vm.showAnswerConfirmation = true
        vm.quizTimersController.startAutoConfirmIfEnabled(duration: 5)

        vm.togglePause()
        #expect(vm.isPaused)
        #expect(vm.autoConfirmCountdown == 0)
        // The toolbar button is only ever disabled in an unpausable state that
        // is also not paused — never on a paused sheet.
        #expect(vm.canPauseQuiz || vm.isPaused, "the resume control must stay live")

        vm.togglePause()

        #expect(vm.isPaused == false)
        #expect(vm.autoConfirmCountdown == Config.autoConfirmDelaySecs,
                "resuming the sheet re-arms its full window")
        vm.quizTimersController.cancelAutoConfirm()
    }

    /// Finding 3 of the #173 review: a pause taken on the question screen used
    /// to ride through to `.showingResult`, where `startAutoAdvanceCountdown`'s
    /// own `guard !isPaused` silently killed auto-advance — the result arrived
    /// pre-paused and the quiz stopped moving hands-free. Acting on the question
    /// is resuming, exactly as confirming already was.
    @Test("answering or skipping a paused question clears the pause")
    func answeringAPausedQuestionResumes() async {
        for answer in ["tap", "skip"] {
            let vm = makeQuestionViewModel(question: Question.previewMCQ)
            vm.togglePause()
            #expect(vm.isPaused)

            if answer == "tap" {
                await vm.submitMCQAnswer(key: "b", value: "Jupiter")
            } else {
                await vm.skipQuestion()
            }

            #expect(vm.isPaused == false,
                    "a \(answer) must not carry the pause onto the result screen")
        }
    }

    /// The result screen keeps its own STAY pill (#131 D) and must keep
    /// listening for "ďalej" — the toolbar pause must not claim that state.
    @Test("the result screen is not a toolbar-pausable state")
    func resultScreenIsNotToolbarPausable() {
        let vm = Fixtures.makeViewModel()
        vm.currentSession = Fixtures.makeActiveSession()
        vm.quizState = .showingResult(question: Question.preview, evaluation: .previewCorrect)
        #expect(vm.canPauseQuiz == false)
    }
}

// MARK: - Evaluating in the button (C2)

@MainActor
@Suite("Answer confirmation — evaluating in the button (#173 C2)")
struct AnswerConfirmationEvaluatingTests {
    private func makeSheet(evaluating: String?) -> AnswerConfirmationView {
        AnswerConfirmationView(
            isProcessing: false,
            transcribedAnswer: .constant("Paris"),
            // A live window: 0 would trip the separate "submit is firing" lock
            // on Re-record and blur what this suite is measuring.
            autoConfirmCountdown: 4,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            evaluatingAnswer: evaluating
        )
    }

    /// The founder's finding 5: the full-screen "Vyhodnocujem" overlay was ugly
    /// and disowned the button that had just been pressed. The state belongs IN
    /// that button — spinner + "Evaluating…", the same catalog key the overlay
    /// used, so SK/CS need nothing new.
    @Test("the primary button becomes the spinning Evaluating… control")
    func primaryButtonShowsEvaluating() throws {
        let tree = try makeSheet(evaluating: "A · Textured wallpaper").inspect()
        #expect(throws: Never.self) { try tree.find(text: "Evaluating…") }
        #expect(throws: (any Error).self, "Confirm is not offered twice for one submission") {
            try tree.find(text: "Confirm")
        }
        let confirm = try tree.find(viewWithAccessibilityIdentifier: "confirmation.confirm")
        #expect(throws: Never.self, "the spinner is the evaluating signal") {
            try confirm.find(ViewType.ProgressView.self)
        }
        // The countdown chip must be gone: nothing is counting down any more.
        #expect(throws: (any Error).self) { try tree.find(text: "4s") }
    }

    /// THE bug the first #173 round shipped: `confirmAnswer()` consumes the
    /// transcript synchronously, so the presenter's "a transcript is still in
    /// flight" test (`.processing` + empty field) is ALSO true for the whole
    /// evaluating window — and it won, so every voice confirm showed
    /// "PROCESSING / Transcribing…" with a Cancel that drops the answer
    /// mid-grade, and the C2 button was never reachable. Evaluating wins now,
    /// and it wins inside the view so no call site can desync the two again.
    @Test("evaluating beats the transcribing spinner even when the presenter says both")
    func evaluatingWinsOverProcessing() throws {
        let view = AnswerConfirmationView(
            // Exactly what QuestionView computes during a voice confirm: the
            // field has been consumed, so its transcribing test is true too.
            isProcessing: true,
            transcribedAnswer: .constant(""),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            onCancel: {},
            evaluatingAnswer: "Paris"
        )
        let tree = try view.inspect()

        #expect(throws: Never.self) { try tree.find(text: "Evaluating…") }
        #expect(throws: Never.self, "the submitted answer stays on screen") {
            try tree.find(text: "Paris")
        }
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.reRecord").isDisabled())
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.edit").isDisabled())
        // The transcribing branch and its answer-dropping Cancel must be gone.
        #expect(throws: (any Error).self) { try tree.find(text: "Transcribing…") }
        #expect(throws: (any Error).self, "Cancel here would drop the answer mid-grade") {
            _ = try tree.find(viewWithAccessibilityIdentifier: "confirmation.cancel")
        }
    }

    /// The same bug's second half: `editingRequested` is `@State` that nothing
    /// resets, and the sheet now outlives Confirm — so "fix my transcript, then
    /// Confirm" kept a LIVE, EMPTY `TextField` bound to the `transcribedAnswer`
    /// that `confirmAnswer()` had just cleared, with its Cancel still hot.
    /// Typing there mutated the answer being graded. Evaluating outranks
    /// editing for exactly the reason it outranks the spinner, and the rule
    /// lives in one pure function so all three branches are pinned at once.
    @Test("evaluating outranks editing and the transcribing spinner alike")
    func evaluatingOutranksEveryOtherBranch() {
        typealias Sheet = AnswerConfirmationView

        // Evaluating wins from either of the states that used to win.
        #expect(Sheet.branch(isProcessing: true, isEditing: false, isEvaluating: true) == .transcript)
        #expect(Sheet.branch(isProcessing: false, isEditing: true, isEvaluating: true) == .transcript,
                "an edited answer must be frozen read-only while it is graded")
        #expect(Sheet.branch(isProcessing: true, isEditing: true, isEvaluating: true) == .transcript)

        // …and neither branch is removed, only outranked.
        #expect(Sheet.branch(isProcessing: true, isEditing: false, isEvaluating: false) == .transcribing)
        #expect(Sheet.branch(isProcessing: false, isEditing: true, isEvaluating: false) == .editing)
        #expect(Sheet.branch(isProcessing: false, isEditing: false, isEvaluating: false) == .transcript)
    }

    /// What the driver sees on that path: their edited words, read-only, under
    /// the spinning button — no live field, no edit-cancel, nothing to type in.
    @Test("an edited answer renders frozen and read-only while it is graded")
    func editedAnswerIsFrozenWhileEvaluating() throws {
        let view = AnswerConfirmationView(
            isProcessing: true,
            // Cleared by confirmAnswer() before the first suspension, exactly
            // as the live sheet sees it.
            transcribedAnswer: .constant(""),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            onCancel: {},
            evaluatingAnswer: "The Eiffel Tower"
        )
        let tree = try view.inspect()

        #expect(throws: Never.self, "the edited words stay on screen") {
            try tree.find(text: "The Eiffel Tower")
        }
        #expect(throws: Never.self) { try tree.find(text: "Evaluating…") }
        #expect(throws: (any Error).self, "a live field here mutates the answer being graded") {
            _ = try tree.find(ViewType.TextField.self)
        }
        #expect(throws: (any Error).self, "its Cancel must go with it") {
            _ = try tree.find(viewWithAccessibilityIdentifier: "confirmation.editCancel")
        }
    }

    /// And the genuine no-transcript-yet case still gets its spinner: this is
    /// only a precedence rule, not a removal.
    @Test("a sheet waiting on a transcript still shows the transcribing state")
    func processingStillWinsWhenNotEvaluating() throws {
        let view = AnswerConfirmationView(
            isProcessing: true,
            transcribedAnswer: .constant(""),
            autoConfirmCountdown: 0,
            autoConfirmEnabled: true,
            autoConfirmTotal: Config.autoConfirmDelaySecs,
            onConfirm: {},
            onReRecord: {},
            onCancel: {}
        )
        let tree = try view.inspect()
        #expect(throws: Never.self) { try tree.find(text: "Transcribing…") }
        #expect(throws: (any Error).self) { try tree.find(text: "Evaluating…") }
    }

    /// Everything else on the sheet is dead while the answer is in flight. A
    /// live Re-record here cancels the in-flight submission mid-grade (#133 V14)
    /// — the driver must not be able to reach it by accident.
    @Test("every other control on the sheet is disabled while evaluating")
    func otherControlsAreDisabledWhileEvaluating() throws {
        let tree = try makeSheet(evaluating: "Paris").inspect()
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.reRecord").isDisabled())
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.edit").isDisabled())
    }

    /// `confirmAnswer()` consumes `transcribedAnswer` on entry (its single-flight
    /// token), so the sheet has to be handed the submitted text or it would flip
    /// to "Nothing heard" the instant the driver confirmed.
    @Test("the submitted answer stays readable while it is being graded")
    func submittedAnswerStaysVisible() throws {
        let tree = try makeSheet(evaluating: "A · Textured wallpaper").inspect()
        #expect(throws: Never.self) { try tree.find(text: "A · Textured wallpaper") }
        #expect(throws: (any Error).self) { try tree.find(text: "Nothing heard") }
    }

    /// And the normal sheet is untouched: Confirm is Confirm, and it is live.
    @Test("a sheet that is not evaluating keeps its live Confirm and Re-record")
    func nonEvaluatingSheetIsUnchanged() throws {
        let tree = try makeSheet(evaluating: nil).inspect()
        #expect(throws: Never.self) { try tree.find(text: "Confirm") }
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.reRecord").isDisabled() == false)
        #expect(try tree.find(viewWithAccessibilityIdentifier: "confirmation.edit").isDisabled() == false)
    }
}

// MARK: - ListenBar above the grid, dismissible per question (B1)

@MainActor
@Suite("MCQ ListenBar — above the options, dismissible per question (#173 B1)")
struct MCQListenBarPlacementTests {
    /// The founder missed the banner entirely below the grid (finding 7). It is
    /// above the options now and carries the ✕ that hides it — MCQ only: the
    /// confirmation sheet and Home have nothing to make room for.
    @Test("the MCQ bar carries the ✕; a bar without a dismiss handler does not")
    func dismissAffordanceIsOptIn() async throws {
        let vm = makeQuestionViewModel(question: Question.previewMCQ)
        vm.settings.autoRecordEnabled = false
        vm.settings.answerTimeLimit = 30
        vm.answerTimerCountdown = 12
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            #expect(throws: Never.self) { try tree.find(viewWithAccessibilityIdentifier: "listen-bar") }
            #expect(throws: Never.self, "the B1 banner must offer a way out") {
                try tree.find(viewWithAccessibilityIdentifier: "listen-bar.dismiss")
            }
        }

        let plain = ListenBar(mode: .command, commandHint: "Say start")
        try await ViewHosting.host(plain) {
            #expect(throws: (any Error).self, "no handler, no ✕") {
                _ = try plain.inspect().find(viewWithAccessibilityIdentifier: "listen-bar.dismiss")
            }
        }
    }

    /// The dismissal is scoped to the question on screen. A remembered dismissal
    /// would quietly remove the only surface naming the hands-free commands for
    /// the rest of the quiz — which is why this is a value with a question id in
    /// it rather than a bare "hidden" flag.
    @Test("a dismissal applies to its own question only")
    func dismissIsScopedToTheCurrentQuestion() {
        var dismissal = ListenBarDismissal()
        #expect(dismissal.isHidden(questionId: "q1") == false)

        dismissal.dismiss(questionId: "q1")

        #expect(dismissal.isHidden(questionId: "q1"))
        #expect(dismissal.isHidden(questionId: "q2") == false,
                "the next question must arm its own bar")
    }

    /// #173 B1 "menšia výška": the bar sits between the stem and the options
    /// now, so every point it takes is a point the options do not get. Home's
    /// slim bar was never in anything's way and is untouched.
    @Test("the quiz-size bar lost height; Home's slim bar is untouched")
    func fullSizeBarIsShorter() {
        #expect(ListenBar.height(size: .full, hasSubLine: true) == 48)
        #expect(ListenBar.height(size: .full, hasSubLine: false) == 38)
        #expect(ListenBar.height(size: .slim, hasSubLine: true) == 40)
    }
}

// MARK: - Replay glyph

@MainActor
@Suite("Replay affordance (#173 finding 6)")
struct QuestionReplayGlyphTests {
    /// #132 dropped the glyph from MCQ "for space" and the founder read the stem
    /// as untappable. Both modes carry it again — and it is
    /// `arrow.counterclockwise`, not a speaker: a speaker glyph sitting next to a
    /// speaker-glyph mute toggle means two opposite things at once.
    @Test("both modes show the replay glyph inside the replay tap target",
          arguments: [Question.previewMCQ, Question.preview])
    func replayGlyphPresentInBothModes(question: Question) async throws {
        let vm = makeQuestionViewModel(question: question)
        let view = QuestionView(viewModel: vm)
        try await ViewHosting.host(view) {
            let tree = try view.inspect()
            let replay = try tree.find(viewWithAccessibilityIdentifier: "question.replay")
            let glyph = try replay.find(viewWithAccessibilityIdentifier: "question.replayGlyph")
            #expect(try glyph.image().actualImage().name() == "arrow.counterclockwise")
        }
    }
}
