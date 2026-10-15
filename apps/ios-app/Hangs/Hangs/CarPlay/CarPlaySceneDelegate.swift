//
//  CarPlaySceneDelegate.swift
//  Hangs
//
//  #97 — CarPlay support. The car's screen is a second scene of the same app
//  (declared in Info.plist, Local builds only):
//  it drives the app's one QuizViewModel, so a round started in the car is the
//  round on the phone, and the other way round.
//

#if CARPLAY
    import CarPlay
    import os

    final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
        /// Set by HangsApp at launch. CarPlay creates this delegate itself, so it
        /// cannot be handed the app state any other way.
        static weak var appState: AppState?

        private var controller: AnyObject?

        func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didConnect interfaceController: CPInterfaceController
        ) {
            Logger.quiz.info("🚗 CarPlay connected")
            // The voice-based conversational category (and its template API)
            // starts at iOS 26.4; earlier systems never list the app in CarPlay.
            guard #available(iOS 26.4, *), let appState = Self.appState else { return }
            let viewModel = appState.sharedQuizViewModel()
            // Launched from the car with the phone locked: no phone window has
            // reported a phase, so it must not count as being in front.
            let phoneWindowInFront = UIApplication.shared.connectedScenes.contains {
                $0.session.role == .windowApplication && $0.activationState == .foregroundActive
            }
            if !phoneWindowInFront {
                viewModel.isPhoneSceneForeground = false
            }
            let controller = CarPlayQuizController(
                interfaceController: interfaceController,
                viewModel: viewModel,
                packOrderService: appState.packOrderService
            )
            controller.start()
            self.controller = controller
        }

        func templateApplicationScene(
            _ templateApplicationScene: CPTemplateApplicationScene,
            didDisconnectInterfaceController interfaceController: CPInterfaceController
        ) {
            Logger.quiz.info("🚗 CarPlay disconnected")
            if #available(iOS 26.4, *) {
                (controller as? CarPlayQuizController)?.stop()
            }
            controller = nil
            Self.appState?.quizViewModel?.handleCarPlayScene(foreground: false)
        }

        func sceneDidBecomeActive(_ scene: UIScene) {
            Self.appState?.quizViewModel?.handleCarPlayScene(foreground: true)
        }

        func sceneDidEnterBackground(_ scene: UIScene) {
            Self.appState?.quizViewModel?.handleCarPlayScene(foreground: false)
        }
    }
#endif
