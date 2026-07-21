//
//  CommandCapturePhaseTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.4. The capture phase is the
//  single source of truth for earcons (77.10). These tests pin WHY it must be
//  additive and strict: an injected lifecycle sequence must produce a
//  deterministic phase sequence (so earcons fire at the right moments), and an
//  ILLEGAL event must be a no-op (never fire a false earcon or advance the UI
//  out of order) — AND it must never leak into QuizState/validTransitions.
//

import Foundation
@testable import Hangs
import Testing

@Suite("CommandCapturePhase")
struct CommandCapturePhaseTests {
    // MARK: - Pure machine

    @Test("Happy-path lifecycle produces the expected phase sequence")
    func happyPath() {
        var phase = CommandCapturePhase.idle
        var sequence: [CommandCapturePhase] = [phase]
        for event in [CaptureLifecycleEvent.arm, .listen, .recognize] {
            phase = phase.applying(event) ?? phase
            sequence.append(phase)
        }
        #expect(sequence == [.idle, .armed, .listening, .listening])
    }

    @Test("recognize is an ack-only self-loop while listening")
    func recognizeIsAckOnly() {
        #expect(CommandCapturePhase.listening.applying(.recognize) == .listening)
        // recognize is illegal outside listening
        #expect(CommandCapturePhase.armed.applying(.recognize) == nil)
        #expect(CommandCapturePhase.idle.applying(.recognize) == nil)
    }

    @Test("reset returns to idle from any phase")
    func resetAlwaysIdle() {
        for phase in CommandCapturePhase.allCases {
            #expect(phase.applying(.reset) == .idle)
        }
    }

    @Test("Illegal transitions are nil (no-op)")
    func illegalTransitionsRejected() {
        #expect(CommandCapturePhase.idle.applying(.listen) == nil)
        #expect(CommandCapturePhase.armed.applying(.arm) == nil)
        #expect(CommandCapturePhase.listening.applying(.arm) == nil)
        #expect(CommandCapturePhase.listening.applying(.listen) == nil)
    }

    // MARK: - View-model wiring

    @Test("applyCaptureEvent drives the observable through the happy path")
    @MainActor
    func viewModelDrivesPhase() {
        let vm = Fixtures.makeViewModel()
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle)
        #expect(vm.voiceCommandCoordinator.applyCaptureEvent(.arm))
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .armed)
        #expect(vm.voiceCommandCoordinator.applyCaptureEvent(.listen))
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .listening)
    }

    @Test("An illegal injected event is rejected and leaves the phase unchanged")
    @MainActor
    func viewModelRejectsIllegal() {
        let vm = Fixtures.makeViewModel()
        // listen is illegal from idle (must arm first)
        #expect(vm.voiceCommandCoordinator.applyCaptureEvent(.listen) == false)
        #expect(vm.voiceCommandCoordinator.commandCapturePhase == .idle)
    }
}
