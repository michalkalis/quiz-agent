//
//  QuizViewModel+ResultPace.swift
//  Hangs
//
//  #240.9 (founder 2026-11-18): the result used to move on a fixed 8 s after
//  it appeared, counting while the verdict was still being spoken. Ten
//  questions were more waiting than playing. Now the countdown starts when the
//  spoken verdict has ended and lasts a short moment; without a spoken verdict
//  it keeps the Settings pause, the time to read the result.
//

import Foundation

extension QuizViewModel {
    /// Plays the result's verdict and returns the auto-advance countdown that
    /// follows it, or nil when the result waits for "next" (#243.8). A spoken
    /// verdict is waited for (at most `Config.spokenVerdictWaitCap`; past that
    /// it keeps playing under the countdown), then the Settings pace
    /// (`resultPaceSeconds`). Muted or no audio: the countdown starts at once.
    func playVerdictThenPace(_ audio: AudioInfo?) async -> Int? {
        // Read aloud off, or silent mode, speaks no verdict (founder
        // 2026-11-22); the result keeps its pause and auto-advance.
        guard !isAudioMuted else { return resultPaceSeconds(afterSpokenVerdict: false) }
        let playback = Task { await playFeedback(audio) }
        guard hasFeedbackAudio(audio) else { return resultPaceSeconds(afterSpokenVerdict: false) }
        // #243.8: no countdown follows, so none is shown or held while the
        // verdict plays; the "next" window opens once it has ended.
        guard let pace = resultPaceSeconds(afterSpokenVerdict: true) else {
            _ = await playback.value
            return nil
        }

        isAwaitingSpokenVerdict = true
        defer { isAwaitingSpokenVerdict = false }
        let (ended, signal) = AsyncStream<Void>.makeStream()
        let watcher = Task {
            _ = await playback.value
            signal.yield()
        }
        let clock = clock
        let cap = Task {
            try? await clock.sleep(for: Config.spokenVerdictWaitCap)
            signal.yield()
        }
        for await _ in ended {
            break
        }
        watcher.cancel()
        cap.cancel()
        return pace
    }

    /// #243.8 (founder 2026-11-24): the seconds the result counts down
    /// before it moves on, or nil when it waits for "next". "Right after the
    /// verdict" is a short beat after a spoken verdict and a reading pause
    /// without one; 8 / 15 s count from the verdict's end either way.
    func resultPaceSeconds(afterSpokenVerdict spoken: Bool) -> Int? {
        let delay = settings.autoAdvanceDelay
        if delay > 0 { return delay }
        if delay == QuizSettings.rightAfterVerdictAutoAdvance {
            return spoken ? Config.pauseAfterSpokenVerdict : Config.resultReadingPause
        }
        return nil
    }

    /// #243.8: the result waits for "next" — open its command window, which
    /// hears only "next" (`VoiceCommandScreen.result`). Called once nothing
    /// is spoken on the result any more.
    func armResultNextCommand() async {
        guard quizState.isShowingResult else { return }
        // Commands are heard only after a line that names them (founder
        // 2026-11-24): "Povedz: ďalšia." Nothing is said with read-aloud off.
        if !isSilentMode, !isAudioMuted {
            await playPhasePrompt(.sayNext)
            guard quizState.isShowingResult else { return }
        }
        resultNextCommandArmed = true
        await voiceCommandCoordinator.syncCommandListenerWindow()
    }

    private func hasFeedbackAudio(_ audio: AudioInfo?) -> Bool {
        audio?.feedbackAudioBase64 != nil || audio?.feedbackUrl != nil
    }

    /// Base64 (enhanced feedback) before the URL (generic feedback).
    private func playFeedback(_ audio: AudioInfo?) async -> TimeInterval {
        if let base64 = audio?.feedbackAudioBase64 {
            return await audioDeviceState.playFeedbackAudioBase64(base64)
        } else if let feedbackUrl = audio?.feedbackUrl {
            return await audioDeviceState.playFeedbackAudio(from: feedbackUrl)
        }
        return 0
    }
}
