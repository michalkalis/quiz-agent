//
//  CommandCapturePhase.swift
//  Hangs
//
//  Issue #77 (voice commands hands-free), task 77.4 — the ADDITIVE capture-phase
//  observable (E-state). This is a SEPARATE axis from QuizState: it is the single
//  source of truth for earcons (77.10), driven off INJECTED audio-lifecycle
//  events. It deliberately does NOT add cases to QuizState / validTransitions —
//  those model the quiz flow, this models the mic/listener capture lifecycle
//  that rides on top of it. (The deferred recording-UI phases .recording /
//  .processing and their .record / .process events were never reachable in
//  production and were deleted in #113 S6a.)
//

import Foundation

/// The mic/command-listener capture lifecycle. Linear, additive to QuizState.
enum CommandCapturePhase: String, Sendable, Equatable, CaseIterable {
    case idle // nothing armed
    case armed // listener attached, not yet consuming audio
    case listening // consuming audio, matching commands
}

/// Injected audio-lifecycle events that drive the capture phase. The recognizer
/// / audio layer (Session 3+) emits these; the phase machine never touches audio.
enum CaptureLifecycleEvent: String, Sendable, Equatable, CaseIterable {
    case arm // attach the listener
    case listen // begin consuming audio
    case recognize // a command was recognized (ack signal; stays listening)
    case reset // tear everything down → idle
}

extension CommandCapturePhase {
    /// Pure transition: the phase reached by applying `event`, or `nil` if the
    /// event is illegal from the current phase (caller treats `nil` as a no-op).
    /// Kept pure so it is testable without the view model and cannot drift from
    /// the observable that mirrors it.
    func applying(_ event: CaptureLifecycleEvent) -> CommandCapturePhase? {
        switch (self, event) {
        case (_, .reset): return .idle
        case (.idle, .arm): return .armed
        case (.armed, .listen): return .listening
        case (.listening, .recognize): return .listening // ack only — no phase change
        default: return nil
        }
    }
}
