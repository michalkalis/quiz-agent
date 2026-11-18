//
//  ShareSheetPresenter.swift
//  Hangs
//
//  Presents the system share sheet over the first scene's topmost view
//  controller. Used by Settings for the account data export and the voice
//  recordings export (#194 A1 moved it out of SettingsView), and by #232 for
//  a shared quiz, whose link exists only after a server call (a `ShareLink`
//  needs its item before the tap).
//

import UIKit

@MainActor
enum ShareSheetPresenter {
    static func present(_ items: [Any]) {
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = windowScene.windows.first?.rootViewController
        else { return }
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(activityVC, animated: true)
    }
}
