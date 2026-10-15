//
//  CarPlayAppDelegate.swift
//  Hangs
//
//  #97 — CarPlay support. Hands the CarPlay scene its delegate in code, so the
//  shared Info.plist needs no CarPlay entry and Staging/Prod builds stay free of it.
//

#if CARPLAY
    import CarPlay
    import UIKit

    final class CarPlayAppDelegate: NSObject, UIApplicationDelegate {
        func application(
            _ application: UIApplication,
            configurationForConnecting connectingSceneSession: UISceneSession,
            options: UIScene.ConnectionOptions
        ) -> UISceneConfiguration {
            let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
            if connectingSceneSession.role == .carTemplateApplication {
                configuration.delegateClass = CarPlaySceneDelegate.self
            }
            return configuration
        }
    }
#endif
