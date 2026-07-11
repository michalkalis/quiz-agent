//
//  QuizViewModel+ScenePhase.swift
//  Hangs
//
//  Scene-phase lifecycle: tear down the microphone INPUT when the app leaves
//  the foreground. UIBackgroundModes audio deliberately stays (question and
//  feedback TTS must keep playing while driving — product decision), but that
//  same mode also kept the SpeechAnalyzer input tap and any in-flight answer
//  recording alive in the background, i.e. the mic stayed hot. Playback
//  continues in the background; input never does.
//

import os
import SwiftUI

extension QuizViewModel {

    /// Route a scene-phase change from HangsApp's WindowGroup.
    /// `.background` tears down all audio input: the command/VAD listener
    /// stops, an in-flight recording aborts via the existing #67 interruption
    /// path, and the audio session is released only when fully idle — never
    /// while TTS is playing. `.active` re-arms the listener via the existing
    /// window sync. `.inactive` is transient (app switcher, incoming call UI)
    /// — no teardown, the #67 interruption path covers real interruptions.
    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Flip the flag FIRST (synchronously): currentCommandScreen returns
            // nil from here on, so a racing refreshCommandWindow() or a
            // post-TTS startSilenceDetectionListening() cannot re-arm the mic.
            isAppForeground = false

            // (a) Tear down the command/VAD listener (idempotent).
            stopSilenceDetectionListening()

            // (b) An in-flight answer recording aborts via the existing #67
            // interruption teardown — the single recording state-reset path
            // (no second reset invented here). That path never touches the
            // batch M4A recorder (on a system interruption AudioService stops
            // it itself), so stop it explicitly for the batch case.
            if quizState == .recording {
                if !isStreamingSTT {
                    Task { [audioService] in _ = try? await audioService.stopRecording() }
                }
                handleAudioInterruption()
            }

            // (c) Release the audio session ONLY when fully idle — never kill
            // in-flight background TTS (the driving use case).
            if quizState == .idle, !audioService.isPlaying {
                audioService.deactivateSession()
            }

            Logger.audio.info("🌙 Scene → background: mic input torn down (playback untouched)")

        case .active:
            isAppForeground = true
            refreshCommandWindow() // re-arm via the existing window sync

        default:
            break
        }
    }
}
