//
//  CommandCapturePhaseTests.swift
//  HangsTests
//
//  Issue #77 (voice commands hands-free), task 77.4. The capture phase is the
//  single source of truth for earcons (77.10) + the deferred recording UI (P5).
//  These tests pin WHY it must be additive and strict: an injected lifecycle
//  sequence must produce a deterministic phase sequence (so earcons fire at the
//  right moments), and an ILLEGAL event must be a no-op (never fire a false
//  earcon or advance the UI out of order) — AND it must never leak into
//  QuizState/validTransitions.
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
        for event in [CaptureLifecycleEvent.arm, .listen, .recognize, .record, .process] {
            phase = phase.applying(event) ?? phase
            sequence.append(phase)
        }
        #expect(sequence == [.idle, .armed, .listening, .listening, .recording, .processing])
    }

    @Test("recognize is an ack-only self-loop while listening")
    func recognizeIsAckOnly() {
        #expect(CommandCapturePhase.listening.applying(.recognize) == .listening)
        // recognize is illegal outside listening
        #expect(CommandCapturePhase.armed.applying(.recognize) == nil)
        #expect(CommandCapturePhase.idle.applying(.recognize) == nil)
    }

    @Test("processing can re-arm for the next screen")
    func reArmFromProcessing() {
        #expect(CommandCapturePhase.processing.applying(.arm) == .armed)
    }

    @Test("reset returns to idle from any phase")
    func resetAlwaysIdle() {
        for phase in CommandCapturePhase.allCases {
            #expect(phase.applying(.reset) == .idle)
        }
    }

    @Test("Illegal transitions are nil (no-op)")
    func illegalTransitionsRejected() {
        #expect(CommandCapturePhase.idle.applying(.record) == nil)
        #expect(CommandCapturePhase.idle.applying(.listen) == nil)
        #expect(CommandCapturePhase.idle.applying(.process) == nil)
        #expect(CommandCapturePhase.armed.applying(.record) == nil)
        #expect(CommandCapturePhase.armed.applying(.process) == nil)
        #expect(CommandCapturePhase.listening.applying(.process) == nil)
        #expect(CommandCapturePhase.recording.applying(.record) == nil)
    }

    // MARK: - View-model wiring

    @Test("applyCaptureEvent drives the observable through the happy path")
    @MainActor
    func viewModelDrivesPhase() {
        let vm = Fixtures.makeViewModel()
        #expect(vm.commandCapturePhase == .idle)
        #expect(vm.applyCaptureEvent(.arm))
        #expect(vm.commandCapturePhase == .armed)
        #expect(vm.applyCaptureEvent(.listen))
        #expect(vm.commandCapturePhase == .listening)
        #expect(vm.applyCaptureEvent(.record))
        #expect(vm.commandCapturePhase == .recording)
        #expect(vm.applyCaptureEvent(.process))
        #expect(vm.commandCapturePhase == .processing)
    }

    @Test("An illegal injected event is rejected and leaves the phase unchanged")
    @MainActor
    func viewModelRejectsIllegal() {
        let vm = Fixtures.makeViewModel()
        // record is illegal from idle
        #expect(vm.applyCaptureEvent(.record) == false)
        #expect(vm.commandCapturePhase == .idle)
    }
}
