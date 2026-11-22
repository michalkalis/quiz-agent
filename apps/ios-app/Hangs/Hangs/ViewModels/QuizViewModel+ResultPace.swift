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
    /// follows it. A spoken verdict is waited for (at most
    /// `Config.spokenVerdictWaitCap`; past that it keeps playing under the
    /// countdown), then `Config.pauseAfterSpokenVerdict`. Muted or no audio:
    /// the countdown starts at once with `settings.autoAdvanceDelay`.
    func playVerdictThenPace(_ audio: AudioInfo?) async -> Int {
        // Read aloud off, or silent mode, speaks no verdict (founder
        // 2026-11-22); the result keeps its pause and auto-advance.
        guard !isAudioMuted else { return settings.autoAdvanceDelay }
        let playback = Task { await playFeedback(audio) }
        guard hasFeedbackAudio(audio) else { return settings.autoAdvanceDelay }

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
        return Config.pauseAfterSpokenVerdict
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
