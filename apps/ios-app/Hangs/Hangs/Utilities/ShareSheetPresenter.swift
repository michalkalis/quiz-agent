//
//  ShareSheetPresenter.swift
//  Hangs
//
//  Presents the system share sheet over the first scene's root view
//  controller. Used by Settings for the account data export and the voice
//  recordings export (#194 A1 moved it out of SettingsView).
//

import UIKit

@MainActor
enum ShareSheetPresenter {
    static func present(_ items: [Any]) {
        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = windowScene.windows.first?.rootViewController
        {
            root.present(activityVC, animated: true)
        }
    }
}
