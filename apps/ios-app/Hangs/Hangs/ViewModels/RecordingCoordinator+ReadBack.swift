//
//  RecordingCoordinator+ReadBack.swift
//  Hangs
//
//  #184 track D — the confirmation sheet reads the recognised VOICE answer back.
//  Founder (car test 2026-09-21): with eyes on the road the sheet's text is
//  unreadable, so a mishearing was only discovered on the result screen. Only a
//  voice answer is read back (the streaming commit and the batch upload both
//  land here); an MCQ tap or a typed answer never reaches this file — the
//  founder called reading a tapped option back "useless" (#178, 2026-09-13).
//
//  Order of events: sheet opens → listener torn down (the app must not
//  transcribe its own voice, #119/#149) → TTS via the generic backend endpoint
//  (`synthesizeSpeech`, cached server-side) → THEN auto-confirm and the
//  "ok"/"again" command window arm. Arming them under the read-back would
//  spend the 5 s auto-confirm on the app talking, and open the mic to it.
//

import Foundation
import os

extension RecordingCoordinator {
    /// Open the confirmation sheet for a voice answer and read `text` back.
    /// The auto-confirm countdown and the command window arm after the
    /// read-back (immediately when muted, empty, or on any TTS failure).
    /// `owner` (#186 step 1) is the attempt that recorded the answer — the
    /// sheet belongs to it; `nil` = the current attempt.
    func presentVoiceTranscript(_ text: String, owner: AttemptID? = nil) {
        let owner = owner ?? attemptLedger.current
        cancelAnswerReadBack()
        transcribedAnswer = text
        noAnswerCaptured = false
        confirmationOwner = owner
        showAnswerConfirmation = true
        verifyConfirmationInvariants(after: "presentVoiceTranscript")

        let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spoken.isEmpty, !isMuted() else {
            armConfirmationTail()
            return
        }

        // Self-hearing guard (#119/#149): no live input tap under app TTS.
        stopSilenceDetectionListening()
        isReadingBackAnswer = true
        setPlayingAnswerReadBack(true)

        let task = Task { [weak self] in
            guard let self else { return }
            var completed = false
            do {
                let audio = try await networkService.synthesizeSpeech(text: spoken)
                try Task.checkCancellation()
                _ = try await audioService.playOpusAudio(audio)
                completed = true
            } catch is CancellationError {
                // cancelAnswerReadBack cancels this task and restores the flags
                // itself. #186 step 2 (found by the sequence harness): a playback
                // stopped from OUTSIDE — the mute or pause button — leaves the task
                // running, and returning here left the read-back flags latched and
                // nothing armed: the sheet never auto-confirmed and voice commands
                // stayed off. That is a read-back cut short, so fall through.
                if Task.isCancelled { return }
            } catch {
                Logger.audio.warning("🔈 Answer read-back failed: \(error, privacy: .public)")
            }
            guard !Task.isCancelled else { return }
            isReadingBackAnswer = false
            setPlayingAnswerReadBack(false)
            // The sheet may have moved on (confirm / re-record / edit) while the
            // audio played — only the read-back that still owns it arms the tail.
            guard showAnswerConfirmation, transcribedAnswer == text,
                  attemptLedger.owns(owner, "answerReadBack.tail") else { return }
            if completed {
                Logger.audio.debug("🔈 Answer read back — arming confirmation tail")
            }
            armConfirmationTail()
        }
        taskBag.add(task, key: .answerReadBack)
    }

    /// Stop an in-flight read-back (confirm, re-record, edit, cancel, dismiss).
    /// No-op when none is playing.
    func cancelAnswerReadBack() {
        guard isReadingBackAnswer else { return }
        isReadingBackAnswer = false
        taskBag.cancel(.answerReadBack)
        setPlayingAnswerReadBack(false)
        Task { [audioService] in await audioService.stopPlayback() }
    }

    /// The tail every voice-sheet opening shares: the auto-confirm countdown
    /// and the #77 "ok"/"again" command window.
    private func armConfirmationTail() {
        startAutoConfirmIfEnabled()
        refreshCommandWindow()
    }
}
