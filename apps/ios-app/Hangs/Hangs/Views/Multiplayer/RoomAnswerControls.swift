//
//  RoomAnswerControls.swift
//  Hangs
//
//  #249.5 (founder 2026-11-26: "buttons like in single mode, so the layout
//  doesn't change needlessly"): a game together answers a typed-answer
//  question with solo's footer (`QuestionVoiceFooter`): Answer (mic) and Type
//  side by side; Type opens solo's capsule field with its send button. The
//  answer time is solo's bar under the question (`RoomListenBar`). A game
//  together has no Skip: running out of time is the way to pass.
//

import SwiftUI

/// Solo's bar under the question, in the room's state (`RoomViewModel.listenPhase`).
/// Its slot stays reserved while it is hidden, so nothing below it moves. Takes
/// values, not the model: the question screen's timeline redraws it each tick.
struct RoomListenBar: View {
    @Environment(\.openURL) private var openURL
    let phase: QuestionListenPhase?
    let secondsLeft: Int?
    /// Solo's "Microphone is off for Trubbo" + Settings (typed-answer question, mic refused).
    let showsMicOff: Bool

    var body: some View {
        ZStack {
            if let phase {
                QuestionListenBar(
                    phase: phase,
                    showsWords: false,
                    size: .full,
                    // The open mic counts down the same shared answer time.
                    answerRemaining: phase == .listening(.open) ? secondsLeft : nil,
                    commandsAccessory: showsMicOff ? .micOff : nil,
                    onOpenSettings: openSystemSettings
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: QuestionListenBar.slotHeight(size: .full))
        .animation(.easeInOut(duration: 0.25), value: phase == nil)
        .accessibilityIdentifier("room.question.bar")
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

/// Answer · Type, or the typed field once Type is tapped (solo's footer).
struct RoomOpenAnswerControls: View {
    @ObservedObject var viewModel: RoomViewModel
    /// Values from the question screen's timeline, so the controls lock the
    /// moment the time runs out (`RoomViewModel.canAnswer` / `canSpeak`).
    let canAnswer: Bool
    let canSpeak: Bool
    var typing: FocusState<Bool>.Binding
    @State private var showsTextInput = false

    var body: some View {
        Group {
            if showsTextInput || !viewModel.typedAnswer.isEmpty {
                textInputRow
            } else {
                HStack(spacing: Theme.Hangs.Spacing.xs) {
                    recordButton
                    typeButton
                }
                // Solo's pair cap: both labels fit side by side without shrinking.
                .dynamicTypeSize(...Metrics.pairTypeCap)
            }
        }
        .onChange(of: viewModel.round?.questionId) { _, _ in showsTextInput = false }
    }

    private var isRecording: Bool { viewModel.voicePhase == .recording }

    private var recordButton: some View {
        HangsPrimaryButton(
            title: isRecording ? "Stop" : "Answer",
            icon: isRecording ? "stop.fill" : "mic.fill",
            isLoading: viewModel.voicePhase == .sending,
            loadingStyle: .spinnerOnly,
            height: QuestionSkipButton.rowHeight,
            tint: isRecording ? Theme.Hangs.Colors.listenStrong : nil,
            singleLineTitle: true
        ) {
            // A refused mic never leaves a dead button: Answer opens typing.
            if viewModel.micDenied, !isRecording {
                openTyping()
            } else {
                Task { await viewModel.toggleRecording() }
            }
        }
        .disabled(!isRecording && !canSpeak && !(viewModel.micDenied && canAnswer))
        .accessibilityIdentifier(isRecording ? "room.answer.stop" : "room.answer.record")
    }

    private var typeButton: some View {
        Button(action: openTyping) {
            Label("Type", systemImage: "keyboard")
                .font(.hangsButton)
                .lineLimit(1)
                .minimumScaleFactor(HangsButtonTitle.singleLineMinimumScale)
                .foregroundColor(Theme.Hangs.Colors.ink)
                .frame(maxWidth: .infinity)
                .frame(height: QuestionSkipButton.rowHeight)
                .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
                .overlay(Capsule().strokeBorder(Theme.Hangs.Colors.subtleBorder, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canType)
        .opacity(canType ? 1 : Metrics.dimmed)
        .accessibilityIdentifier("room.answer.type")
    }

    private var canType: Bool { canAnswer && viewModel.voicePhase == .idle }

    /// Solo's typed row: a capsule field and the round send button beside it.
    private var textInputRow: some View {
        let empty = viewModel.typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: Theme.Hangs.Spacing.xs) {
            TextField("Type your answer…", text: $viewModel.typedAnswer)
                .font(.hangsBody(Metrics.typedAnswerSize, weight: .semibold))
                .foregroundColor(Theme.Hangs.Colors.ink)
                .focused(typing)
                .submitLabel(.send)
                .onSubmit { Task { await viewModel.submitTypedAnswer() } }
                .limitLength($viewModel.typedAnswer, to: RoomViewModel.maxAnswerLength)
                .padding(.horizontal, Theme.Hangs.Spacing.lg)
                .frame(maxWidth: .infinity, minHeight: QuestionSkipButton.rowHeight)
                .background(Capsule().fill(Theme.Hangs.Colors.bgCard))
                .overlay(Capsule().strokeBorder(Theme.Hangs.Colors.ink, lineWidth: 1.5))
                .accessibilityIdentifier("room.answer.field")
            Button {
                Task { await viewModel.submitTypedAnswer() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.hangsBody(Metrics.glyphSize, weight: .bold))
                    .foregroundColor(empty ? Theme.Hangs.Colors.muted : Theme.Hangs.Colors.textOnAction)
                    .frame(width: QuestionSkipButton.compactRowHeight, height: QuestionSkipButton.compactRowHeight)
                    .background(Circle().fill(empty ? Theme.Hangs.Colors.mutedBorder : Theme.Hangs.Colors.action))
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .accessibilityLabel(Text("Send answer"))
            .accessibilityIdentifier("room.answer.send")
        }
        .disabled(!canAnswer)
    }

    private func openTyping() {
        showsTextInput = true
        typing.wrappedValue = true
    }

    /// Solo's footer values (`QuestionVoiceFooter`).
    private enum Metrics {
        static let pairTypeCap = DynamicTypeSize.xLarge
        static let glyphSize: CGFloat = 17
        static let typedAnswerSize: CGFloat = 20
        static let dimmed = 0.45
    }
}
