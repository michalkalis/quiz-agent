//
//  AudioSessionNotificationTests.swift
//  HangsTests
//
//  #180 track G: audio interruptions and route changes as unit tests driven by
//  the notifications iOS posts — no simulator audio session, no real phone call.
//
//  The mock-driven interruption tests in AudioServiceTests prove what happens once
//  the service KNOWS an interruption began. These tests close the gap in front of
//  that: the notification name, the userInfo keys and the NSNumber payloads the
//  system sends are decoded by one pure function that the real service and the
//  mock both dispatch on. A wrong key or a wrong raw-value cast would leave the
//  app deaf to phone calls in production while every mock-driven test stayed green.
//

@preconcurrency import AVFoundation
import Combine
import Foundation
@testable import Hangs
import Testing

// MARK: - Payloads as iOS posts them

/// iOS boxes the raw values in `NSNumber`; a test that posted Swift `UInt`s would
/// pass even if the decoder stopped bridging correctly.
@MainActor
private func interruptionNotification(
    _ type: AVAudioSession.InterruptionType,
    options: AVAudioSession.InterruptionOptions = []
) -> Notification {
    var userInfo: [AnyHashable: Any] = [
        AVAudioSessionInterruptionTypeKey: NSNumber(value: type.rawValue),
    ]
    if type == .ended {
        userInfo[AVAudioSessionInterruptionOptionKey] = NSNumber(value: options.rawValue)
    }
    return Notification(
        name: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance(),
        userInfo: userInfo
    )
}

@MainActor
private func routeChangeNotification(_ reason: AVAudioSession.RouteChangeReason) -> Notification {
    Notification(
        name: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance(),
        userInfo: [AVAudioSessionRouteChangeReasonKey: NSNumber(value: reason.rawValue)]
    )
}

// MARK: - Decoding the system payload

@Suite("Audio session notification decoding")
@MainActor
struct AudioSessionNotificationDecodingTests {
    @Test("an interruption .began is recognised from the NSNumber payload")
    func beganDecodes() {
        #expect(AudioService.interruptionPhase(from: interruptionNotification(.began)) == .began)
    }

    @Test("an .ended carrying .shouldResume asks for the session to come back")
    func endedWithResumeDecodes() {
        let phase = AudioService.interruptionPhase(from: interruptionNotification(.ended, options: [.shouldResume]))
        #expect(phase == .ended(shouldResume: true))
    }

    @Test("an .ended without .shouldResume leaves the session alone")
    func endedWithoutResumeDecodes() {
        let phase = AudioService.interruptionPhase(from: interruptionNotification(.ended))
        #expect(phase == .ended(shouldResume: false))
    }

    @Test("a notification without the type key is not an interruption")
    func malformedInterruptionIsIgnored() {
        // Treating a malformed payload as `.began` would tear down a live recording
        // for no reason — the decoder must say "nothing" rather than guess.
        let empty = Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [:])
        #expect(AudioService.interruptionPhase(from: empty) == nil)
    }

    @Test("a route-change reason is recognised from the NSNumber payload")
    func routeChangeReasonDecodes() {
        let reason = AudioService.routeChangeReason(from: routeChangeNotification(.oldDeviceUnavailable))
        #expect(reason == .oldDeviceUnavailable)
    }

    @Test("a route change without a reason is ignored")
    func malformedRouteChangeIsIgnored() {
        let empty = Notification(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [:])
        #expect(AudioService.routeChangeReason(from: empty) == nil)
    }
}

// MARK: - The real service on a posted notification

@Suite("AudioService reacts to posted notifications")
@MainActor
struct AudioServicePostedNotificationTests {
    @Test("every interruption reaches the owner, even with no engine of ours live")
    func idleInterruptionNotifiesOwner() async {
        // #208.8: the quiz answer records on the shared listener engine, not on
        // one of AudioService's, so the service cannot tell whether a recording
        // was lost — the owner decides (it no-ops unless it is recording; see
        // QuizInterruptionNotificationTests). Reporting only its own engine left
        // a call mid-answer stranded in .recording.
        let center = NotificationCenter()
        let service = AudioService(notificationCenter: center)
        service.registerSessionObservers()
        var notified = false
        service.onInterruptionBegan = { notified = true }

        center.post(interruptionNotification(.began))
        for _ in 0 ..< 20 { await Task.yield() }

        #expect(notified == true)
        #expect(service.isRecording == false)
    }

    @Test("re-configuring the session does not stack a second route-change handler")
    func observersAreRegisteredOnce() async {
        // Every session-configuration path registers the observers; without the
        // remove-then-add guard each route flip refreshes the device list N times.
        // How many `@Published` writes one refresh makes depends on the simulator's
        // inputs, so the baseline is measured with one registration and a second
        // registration must not change it.
        let center = NotificationCenter()
        let service = AudioService(notificationCenter: center)
        var publishes = 0
        let subscription = service.objectWillChange.sink { _ in publishes += 1 }
        defer { subscription.cancel() }

        func publishesForOneRouteChange() async -> Int {
            publishes = 0
            center.post(routeChangeNotification(.newDeviceAvailable))
            await pumpUntil({ publishes >= 1 }, "the route change must reach the service")
            for _ in 0 ..< 20 { await Task.yield() }
            return publishes
        }

        service.registerSessionObservers()
        let baseline = await publishesForOneRouteChange()

        service.registerSessionObservers()
        let afterReconfigure = await publishesForOneRouteChange()

        #expect(afterReconfigure == baseline, "a second registration must replace the first, not add to it")
    }
}

// MARK: - The quiz state machine on a posted interruption

@Suite("Quiz state machine on a posted interruption")
@MainActor
struct QuizInterruptionNotificationTests {
    @Test("a phone call mid-recording resets the question to ready with a visible message")
    func callDuringRecordingResetsToReady() async throws {
        let center = NotificationCenter()
        let (viewModel, mockAudio) = Fixtures.makeViewModelWithAudio(notificationCenter: center)
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.quizState = .askingQuestion
        await viewModel.recordingCoordinator.startRecording()
        #expect(viewModel.isAnswerCaptureActive)

        center.post(interruptionNotification(.began))
        await pumpUntil({ viewModel.quizState == .askingQuestion }, "the interruption must leave .recording")

        #expect(viewModel.isAnswerCaptureActive == false, "no capture may survive the call")
        #expect(mockAudio.isRecording == false)
        #expect(viewModel.errorMessage != nil, "the driver must be told why the mic stopped")
    }

    @Test("a phone call while the question is only showing changes nothing on screen")
    func callWhileNotRecordingKeepsTheQuestion() async throws {
        // The owner hears about every interruption now; a call while the mic is
        // shut must not surface "Recording interrupted" or move the quiz.
        let center = NotificationCenter()
        let (viewModel, _) = Fixtures.makeViewModelWithAudio(notificationCenter: center)
        viewModel.currentSession = Fixtures.makeActiveSession()
        viewModel.currentQuestion = Fixtures.makeQuestion()
        viewModel.quizState = .askingQuestion

        center.post(interruptionNotification(.began))
        for _ in 0 ..< 50 { await Task.yield() }

        #expect(viewModel.quizState == .askingQuestion)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("when the call ends with .shouldResume the next mic tap works without a replay")
    func resumableEndRestoresTheMic() async throws {
        let center = NotificationCenter()
        let (_, mockAudio) = Fixtures.makeViewModelWithAudio(notificationCenter: center)
        try await mockAudio.startStreamingRecording { _ in }

        center.post(interruptionNotification(.began))
        await pumpUntil({ mockAudio.isRecording == false }, "the interruption must stop the recording")
        await #expect(throws: AudioError.recordingFailed) {
            try await mockAudio.startStreamingRecording { _ in }
        }

        center.post(interruptionNotification(.ended, options: [.shouldResume]))
        await pumpUntil({ mockAudio.sessionActive }, "a resumable .ended must reactivate the session")

        try await mockAudio.startStreamingRecording { _ in }
        #expect(mockAudio.isRecording == true)
    }
}
