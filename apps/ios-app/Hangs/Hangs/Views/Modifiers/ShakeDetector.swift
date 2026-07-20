//
//  ShakeDetector.swift
//  Hangs
//
//  Device-shake → in-app feedback entry point (#109). The motion event is
//  observed at the window level (`motionEnded`) and rebroadcast as a
//  Notification so any SwiftUI view can react via `.onShake { }`. This replaces
//  Sentry's built-in shake widget (removed in HangsApp.init) so there is exactly
//  one feedback UI.
//

import SwiftUI
import UIKit

extension UIDevice {
    /// Posted whenever the device is shaken (see the `UIWindow` override below).
    static let deviceDidShakeNotification = Notification.Name("com.missinghue.hangs.deviceDidShake")
}

extension UIWindow {
    /// Motion events bubble up the responder chain to the window; catching them
    /// here means the whole app is covered regardless of the first responder.
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: UIDevice.deviceDidShakeNotification, object: nil)
        }
    }
}

private struct ShakeDetectorModifier: ViewModifier {
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(
            NotificationCenter.default.publisher(for: UIDevice.deviceDidShakeNotification)
        ) { _ in
            action()
        }
    }
}

extension View {
    /// Run `action` when the device is shaken.
    func onShake(perform action: @escaping () -> Void) -> some View {
        modifier(ShakeDetectorModifier(action: action))
    }
}
