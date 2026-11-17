# System Calls Coverage — Hangs iOS

Why this exists (#235.4 — tests beyond the happy path): build 87 crashed on
the very first launch after install although ~2 000 unit tests were green.
Every test replaced the clipboard check with a closure, so the real call to
`UIPasteboard.detectPatterns` first ran on a tester's phone. iOS answered it on
a background queue, the handler had inherited the class's `@MainActor`, and
the Swift runtime trapped (#798).

This page lists every place where app code hands a callback to an Apple
framework (completion handler, delegate, notification observer, KVO, async
stream, or a continuation around one), on which thread iOS calls back, whether
the callback is safe there, and which test runs the **real** call. Calls that
cannot run on the simulator are marked "device only" and are covered by the
manual checklist at the end.

How "isolation safe?" was decided: the target builds with
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so every closure written in app
code is main-actor unless it is `@Sendable`/`nonisolated`. A main-actor
closure handed to the system starts with a runtime check and traps when iOS
calls it from another thread. The list was
cross-checked against the built binary (Debug-Local, 2026-11-17): of the
callbacks handed to the system, only the rows marked "main-actor" carry that
check. Completion handlers of Apple APIs that also have an `async` form are
imported as `@Sendable` and are not checked.

Real-call tests live in `HangsTests/RealSystemCallTests.swift` unless named
otherwise. Tests marked *(answered)* need the simulator to have a stored
microphone/speech answer (the local iPhone 18 Pro has one); on a fresh
simulator, such as CI, they are skipped visibly instead of raising a prompt.

## Inventory

| Call | Where | Callback thread | Isolation safe? | Real-call test |
|---|---|---|---|---|
| Clipboard: `UIPasteboard.detectPatterns` | `SharedQuizInbox.clipboardProbablyHasURL` | background queue (not documented; seen in the build 87 crash) | yes since #798: `nonisolated` + `@Sendable` handler | `SharedQuizLinkTests.realClipboardCheckDoesNotCrash` |
| Paste: `NSItemProvider.loadObject` (URL, text) in a checked continuation | `SharedQuizInbox.loadURL` / `loadText` | not documented | yes: SDK handler is `@Sendable`; resumed exactly once | `pastedItemProvidersLoad` |
| System Paste button (`PasteButton` action) | `HomeSharedQuizPasteRow` | not documented (UIKit paste control) | main-actor: safe only if SwiftUI calls it on main (unverified) | device only: the secure Paste button takes only a real finger |
| Share sheet: `UIActivityViewController` + `UIActivityItemSource` | `ShareSheetPresenter`, `ShareTextItem` | not documented; main on the iOS 27 simulator | main-actor: `ShareTextItem` traps if UIKit ever asks off main | `shareSheetReadsPreview` (header); picking a target: device only |
| Microphone permission: `AVAudioApplication.requestRecordPermission` in a continuation | `AudioService.requestMicrophonePermission` | "may be called in a different thread" (AVAudioApplication.h) | yes: completion imported `@Sendable`, no check in the binary | `microphonePermissionRequest` *(answered)*; answering the first prompt: device only |
| Speech permission read: `SFSpeechRecognizer.authorizationStatus` (#237: launch, language switch and every listening window; never prompts) | `SilenceDetectionService.authorizationStatusProvider` | synchronous read, no callback | n/a | `speechPermissionStatusRead` |
| Speech permission: `SFSpeechRecognizer.requestAuthorization` in a continuation (#237: only from "Turn on commands", onboarding or listen bar) | `SilenceDetectionService.requestSystemAuthorization` | not documented (not the recognizer's queue, SFSpeechRecognizer.h) | yes: `nonisolated` + `@Sendable` | `speechPermissionRequest` *(answered)*; first prompt: device only |
| Sign in with Apple: `getCredentialState` in a continuation | `AuthService.checkAppleCredentialState` (actor) | not documented | yes: completion imported `@Sendable`; resumed once | `appleCredentialStateCheck` |
| Sign in with Apple: `credentialRevokedNotification` observer (`queue: nil`) | `AuthService.setupAppleCredentialObservation` | the posting thread (not documented) | yes: `@Sendable` block, hops into the actor | device only: needs revoking the app in iOS Settings |
| Sign in with Apple button (`onRequest` / `onCompletion`) | `SettingsView`, `ContextualSignInSheet` | not documented (SwiftUI) | main-actor (view closures) | device only: the Apple ID sheet needs a person |
| Network path: `NWPathMonitor.pathUpdateHandler` in a checked continuation | `LocalNetworkCheck.isOffCellular` | the private serial queue passed to `start` | yes: SDK handler `@Sendable`; handler cleared after the first path, so resumed once | `networkPathCheck` |
| Phone calls: `CXCallObserver.calls` | `CallMonitor` | synchronous read, no callback | n/a | `callObserverRead` |
| Audio session: `setCategory` / `setActive` | `AudioService.setupAudioSession` | synchronous | n/a | `quizAudioSessionConfiguration` *(answered)* |
| Audio route change + interruption observers (`queue: .main`) | `AudioService.registerSessionObservers`, `TextDictation`, `SilenceDetectionService+Telemetry`, `SettingsView` (`receive(on: main)`) | posted by iOS on its own thread, delivered on main by the queue | yes: `@Sendable` blocks, `nonisolated` handlers that hop to main | device only: the simulator posts no route change; an interruption needs a call or Siri (posted-notification tests: `AudioSessionNotificationTests`) |
| Engine reconfiguration: `AVAudioEngineConfigurationChange` (`queue: .main`) | `SilenceDetectionService+Telemetry` | delivered on main by the queue | yes: `@Sendable` block | device only: needs a live microphone engine |
| Volume: KVO on `AVAudioSession.outputVolume` | `VolumeChangeMonitor` | not documented | yes: KVO handler `@Sendable`, hops to main | device only: hardware volume buttons |
| Microphone tap: `installTap` + `AVAudioConverter` input block | `AudioService` streaming path, `SilenceDetectionService+InputTap`, `+NeuralVAD` | audio I/O thread | yes: `@Sendable` tap, converter block in `nonisolated` code | device only: needs microphone capture |
| Recorder: `AVAudioRecorderDelegate` | `AudioService` | not documented | yes: `nonisolated` methods, hop to main | device only: records sound |
| Playback: `AVPlayer` KVO `timeControlStatus`, end/failed notifications (`queue: .main`), stall `Timer` | `AudioService` playback | KVO not documented; notifications on main by the queue; timer on the main run loop | yes: `@Sendable` closures, hop to main | device only: plays sound |
| Speech engine: `SpeechAnalyzer`, `SpeechTranscriber`/`DictationTranscriber`, `SpeechDetector` results, `AssetInventory` | `SilenceDetectionService+Engine`, `CommandTranscriberAdapter` | async sequences read inside app `Task`s (no closure handed over) | yes | device only: the simulator has no speech assets and no microphone |
| Store: `Product.products`, `purchase()`, `Transaction.updates` | `StoreKitPackPurchaseService` | async API; updates read in a detached task | yes | opt-in `StoreKitSessionSmokeTests` (the StoreKit test daemon was unreachable from `xcodebuild` on the iOS 26.5 simulator; not re-checked on 27.0); real purchase: device only |
| Subscriptions: RevenueCat `Purchases` (customer info stream, purchase, restore) | `LivePurchaseService` | async API (third-party SDK) | yes | device only: needs a sandbox account |
| App Attest: `DCAppAttestService` | `AppAttestor` | async API | yes | device only: not supported on the simulator (compiled out there) |
| Web page: `WKNavigationDelegate` / `WKUIDelegate` | `WebViewRepresentable.Coordinator` (question source) | main (WebKit's delegate protocols are main-actor) | yes | `sourcePageNavigationDelegate` |
| CarPlay: scene delegate, `CPInterfaceControllerDelegate`, button / list item handlers, `popToRootTemplate` completion | `CarPlay/` | handlers: CarPlay's own queue (seen on the iOS 26.5 simulator); scene delegate: main | yes: `nonisolated` handler factories, `@Sendable`, hop to main; scene delegate main-actor | device only: CarPlay build flag + a car or the CarPlay simulator |
| App lifecycle: scene phase, `onOpenURL` | `HangsApp` | main (SwiftUI) | yes | scene activation runs in every `HangsUITests` launch; a tapped quiz link: device only |
| Main-queue hops: `DispatchQueue.main.asyncAfter` | `AnswerConfirmationView.beginEditing` | main | yes | none needed (main to main) |
| UI-test harness: `NWListener` / `NWConnection` handlers (DEBUG only) | `UITestSupport` | a global queue | yes: `nonisolated` handler, hops to main | every `HangsUITests` scenario that talks to `127.0.0.1:9999` |

## Manual pre-release checklist (device only)

Run on a TestFlight build, on a phone that has never had the app (delete it
first), with a pair of headphones or a car nearby. Each step must end with the
app still open and doing what it says; a jump back to the home screen is a
crash, write down the step.

1. **Clipboard on first launch.** Copy a quiz link from a friend's message
   (`https://trubbo.app/play?s=…`), install the app, open it. Home shows "Got a
   quiz link from a friend?".
2. **Paste button.** Tap **Paste** on that row and allow pasting. The friend's
   quiz starts.
3. **Microphone and speech prompts.** Go through onboarding and answer **Allow**
   to the microphone prompt and the speech recognition prompt. The app keeps
   going to the next screen.
4. **Share a quiz.** Finish a quiz and tap share. The share sheet shows the
   Trubbo icon and the quiz title; pick **Messages** or **Copy**. The message
   holds the link.
5. **Sign in with Apple.** In Settings, sign in with Apple and finish the Apple
   sheet. Settings shows your account.
6. **Revoked sign-in.** In iOS Settings → your name → Sign in with Apple →
   Trubbo → Stop using. Open the app again: it works as a guest.
7. **Voice answer.** Start a quiz and answer one question by voice. The answer
   is heard and judged.
8. **Headphones mid-quiz.** During a question, connect then disconnect
   Bluetooth headphones (or the car). Sound moves and the quiz continues.
9. **Phone call mid-question.** Have someone call you while the app listens for
   an answer; decline. The question can be answered again.
10. **Volume buttons.** Press volume up and down during a quiz. Nothing else
    changes.
11. **Purchase.** Buy the smallest pack with a sandbox account, then restore
    purchases in Settings. The pack shows as bought.
12. **CarPlay.** Connect to a car (or Xcode's CarPlay simulator), start a round
    from the car screen, pick a category from the list. The round starts.
