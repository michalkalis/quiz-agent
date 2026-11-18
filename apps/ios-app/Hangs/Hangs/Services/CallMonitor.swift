//
//  CallMonitor.swift
//  Hangs
//
//  #212.4: leaving the app for a phone call is not "left during a question".
//

import CallKit

@MainActor
protocol CallStatusProviding: AnyObject {
    var isOnCall: Bool { get }
}

/// Reads the system's ongoing calls (cellular, FaceTime, VoIP) without any
/// permission prompt.
@MainActor
final class CallMonitor: CallStatusProviding {
    private let observer = CXCallObserver()

    var isOnCall: Bool { observer.calls.contains { !$0.hasEnded } }
}
