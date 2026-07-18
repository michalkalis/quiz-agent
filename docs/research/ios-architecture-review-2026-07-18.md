# iOS Architecture Review — 2026-07-18

**Scope:** full iOS app at `apps/ios-app` (SwiftUI, scheme "Hangs", ships as "Trubbo"; ~110 app-source Swift files, deployment target iOS 18.0).
**Method:** 9 parallel dimension reviewers, every finding passed through adversarial verification; only confirmed findings appear below.
**Context:** solo-founder product, zero external users — correctness and future maintainability weighted over live-client risk.

## Current-state architecture

- **Layers:** `HangsApp` (@main, Sentry + warm-up) → `AppState` (DI container: protocol services, StoreManager, AuthService; zero @Published) → `ContentView` (root router switching on `QuizViewModel.quizState` + sheet host) → screens.
- **Dominant pattern:** one shared `QuizViewModel` (@ObservedObject handed down) + view-local @State for pure presentation flags.
- **Pattern holds:** HomeView, QuestionView, ResultView, CompletionView, MinimizedQuizView, AudioDevicePickerView, ErrorView (all on QuizViewModel); OnboardingView→OnboardingViewModel and OrderPackView/OrderProgressView→OrderPackViewModel are the clean textbook MVVM instances; AnswerConfirmationView, LiveTranscriptView, ImageQuestionView, SourceWebView are dumb components (bindings/callbacks only).
- **Pattern breaks:** SettingsView and ContextualSignInSheet run the whole auth flow view-side (duplicated); PaywallView binds straight to the service-layer StoreManager; MyPacksView calls PackOrderService directly while its sibling pack screens use a VM.
- **Cross-cutting reality:** QuizViewModel is a ~3,000-line god object owning 8 screens' state (incl. paywall + settings toggles), so "3 ViewModels for 21 views" is really 1 monolith + 2 islands. Pack-flow navigation is coordinated via NotificationCenter + NavigationStack identity reset. AppState doubles as a service locator with a weak QuizViewModel back-reference that scene-phase and purchase callbacks depend on.
- **Composition roots:** HangsApp is thin and sound; ContentView is acceptable as router but accretes business logic (sign-in prompt gating, Keychain read) and hosts ErrorView inline.
- **Concurrency:** genuinely Swift 6 + strict complete + MainActor-default (app target); services are @MainActor or actors; zero unsafe escapes.
- **Legacy residue:** an entire dead pre-redesign component layer (13 files), dead LanguagePickerView, two parallel theme systems (Theme.Colors vs Theme.Hangs.Colors).

## Findings

### 1. Overall architecture & uniformity

- **QuizViewModel is a god object — 3,017 lines across 6 files — owning state and business logic for 8+ screens plus paywall, quota, audio devices, voice commands, and timers; no screen can be understood, tested, or changed in isolation** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:100` — split along existing extension seams into per-concern observables (QuizSessionVM, PaywallState, AudioDeviceState, VoiceCommandState) composed by a slim coordinator, one screen at a time. *(Also the top size/SRP finding — see dimension 7 for the concrete coordinator split.)*
- **SettingsView embeds the full Apple sign-in / sign-out / delete-account / export-data business logic in the View (direct KeychainTokenStore reads, async service orchestration), with no ViewModel** — `apps/ios-app/Hangs/Hangs/Views/SettingsView.swift:460` — extract an AccountViewModel (sign-in/out, delete, export, token state) shared with ContextualSignInSheet; keep only presentation @State in the view.
- **ContextualSignInSheet duplicates SettingsView's Apple sign-in completion flow, and the two copies have already diverged in error handling** — `apps/ios-app/Hangs/Hangs/Views/ContextualSignInSheet.swift:201` — move the shared onRequest/onCompletion handling into the one AccountViewModel (or an AppleSignInCoordinator) consumed by both views.
- **PaywallView binds directly to the concrete service-layer StoreManager with no ViewModel; purchase triggering, success auto-dismiss timing, and plan-fallback selection live in the View on the revenue-critical screen** — `apps/ios-app/Hangs/Hangs/Views/PaywallView.swift:27` — introduce a PaywallViewModel wrapping StoreManager that owns plan selection, effectivePlan fallback, and post-success dismissal.
- **MyPacksView calls PackOrderServiceProtocol directly with view-local @State while its sibling #95 — custom quiz packs screens go through OrderPackViewModel — two contradictory patterns inside one flow** — `apps/ios-app/Hangs/Hangs/Views/MyPacksView.swift:14` — move listOrders + loading/failure state into OrderPackViewModel (or a small MyPacksViewModel).
- **AppState is simultaneously DI container and mutable service locator: a weak QuizViewModel back-reference that scene-phase routing silently no-ops on and purchase-success falls back around when unregistered** — `apps/ios-app/Hangs/Hangs/Utilities/AppState.swift:29` — route scenePhase and purchase-success through an explicit long-lived object (session coordinator or Combine subject) the VM subscribes to.
- **ErrorView — a full user-facing screen with CTA routing — is defined inside ContentView.swift, hiding it from Views/ and pushing ContentView to 341 lines (past the ~300-line guideline)** — `apps/ios-app/Hangs/Hangs/ContentView.swift:213` — move it to Views/ErrorView.swift.

*(NotificationCenter pack navigation and dead LanguagePickerView merged into dimensions 4 and 6 respectively.)*

### 2. Modularity & dependency injection

- **Views bypass the AuthService DI seam: five sites in SettingsView construct ad hoc `KeychainTokenStore()` instances to read sign-in state, because AuthServiceProtocol exposes no accessor — signed-in UI state cannot be mocked** — `apps/ios-app/Hangs/Hangs/Views/SettingsView.swift:114` — add isSignedIn/currentAccount to AuthServiceProtocol and read through appState.authService.
- **ContentView also reaches around the injected graph, constructing its own KeychainTokenStore() to decide sign-in-prompt eligibility** — `apps/ios-app/Hangs/Hangs/ContentView.swift:196` — same fix: read isSignedIn via appState.authService.
- **AdminKeyStore has no protocol abstraction and is instantiated directly inside SettingsView, separate from PackOrderService's own instance — admin-key UI state can't be substituted in tests** — `apps/ios-app/Hangs/Hangs/Views/SettingsView.swift:115` — give it a protocol seam mirroring TokenStore and inject one instance through AppState.

### 3. State management

A QuizState enum with a validated transition table exists and is the real render driver — but it is respected unevenly, and ~50 free variables orbit it.

- **startNewQuiz() ignores the rejected transition and has no single-flight guard: ErrorView's "Try Again" runs the whole session-creation flow while quizState stays .error (error→startingQuiz is not in the table), and a double-tap fires two concurrent createSession calls that clobber currentSession** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:555` — guard on the transition result (add error→startingQuiz), add an isStarting flag, matching submitMCQAnswer's pattern.
- **The skip undo-window expiry rechecks only pendingSkipWindow, never quizState, so speaking/tapping during the 2.5s window lets expiry commit skipQuestion() mid-.recording — leaving the streaming mic live into the result — or fire a concurrent skip against an in-flight answer** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:1069` — guard expiry on quizState == .askingQuestion; cancel .skipUndo/pendingSkipWindow in startRecording and submitMCQAnswer.
- **~36 @Published + ~17 non-observable mutable vars express roughly 10 independent axes as ~50 free variables; the recording and confirmation clusters are de-facto sub-states of quizState reset by hand at 8+ sites (resetState misses pendingSkipWindow and activeErrorModel)** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:103` — fold phase-scoped fields into QuizState associated values or per-phase sub-structs (RecordingState, ConfirmationState) so leaving a phase drops its state atomically.
- **handleBargeIn sets isAutoRecording = true before awaiting startRecording, whose foreground guard can bail without resetting it (same pattern at +Timers.swift:31/57), stranding an invalid state that later wrongly arms silence detection on a manual batch recording** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel+Audio.swift:84` — set the flag inside startRecording after guards pass (pass autoStarted as a parameter), or model recording mode as an enum in .recording.
- **The .finished transition never clears isMinimized and nothing cancels auto-advance on minimize, so minimizing on the last result yields CompletionView with a stale MinimizedQuizView floating on top** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:1379` — reset isMinimized on entering .finished, or gate ContentView's overlay on canMinimize.
- **CommandCapturePhase declares .recording/.processing phases that no production call site ever reaches — a second, half-wired state machine for the mic-capture axis whose header still claims single-source-of-truth** — `apps/ios-app/Hangs/Hangs/Utilities/CommandCapturePhase.swift:20` — either fire .record/.process from startRecording/handleCommittedTranscript or delete the dead phases and events.
- **MCQ selection has two sources of truth (view-local selectedKey vs VM mcqVoiceMatchedKey, local-wins): a tap on A followed by a voice match of B submits B while the UI keeps A highlighted** — `apps/ios-app/Hangs/Hangs/Views/Components/MCQOptionPicker.swift:44` — make the VM the single owner of the selected key; drop the view-local @State.
- **The full-screen error is stored in three drift-prone places (.error associated value, never-reset activeErrorModel, separate errorMessage channel); any future .error entry bypassing setError renders a stale prior error** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:697` — carry AppErrorModel in the .error associated value as the only store; clear/delete activeErrorModel.
- **autoAdvanceEnabled is a write-only-true boolean (every assignment is `= true`) yet ResultView and the countdown branch on it as a "setting" — a dead state axis** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:148` — delete it (pause is covered by currentQuestionPaused) or wire it to a real QuizSettings field.
- **score/questionsAnswered are cached projections of currentSession refreshed only inside an `if let participant` guard, so an empty-participants response leaves stale values that CompletionView displays** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:1259` — derive them as computed properties over currentSession.

### 4. Navigation

- **The "start" voice command calls startNewQuiz() directly and never triggers the .packQuizStarted stack teardown, so saying "start" while Settings/OrderPack/MyPacks is pushed leaves that screen covering the freshly-started QuestionView** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel+CommandListener.swift:169` — move the stack reset into startNewQuiz() itself (or route every call site through one path) so it can't be bypassed.
- **ContentView bridges two incompatible navigation models — quizState-keyed root swap vs a real NavigationStack push chain — by force-recreating the stack's identity (`navStackID = UUID()` + `.id()`) on a NotificationCenter broadcast fired from a single call site (SettingsView.playPack:647), hidden global coupling that any listener/ordering change breaks silently for the #95 — custom quiz packs flow** — `apps/ios-app/Hangs/Hangs/ContentView.swift:186` — replace the notification + identity reset with an owned NavigationPath/route enum cleared where quizState transitions away from idle.
- **Repo memory's #80 — custom swipe-to-go-back concern is stale (already reverted to native back); the live risk is ResultView stacking interactiveMinimize with two more independent Drag/Tap recognizers over an inner ScrollView with no shared arbitration** — `apps/ios-app/Hangs/Hangs/Views/ResultView.swift:55` — verify on device that pull-to-minimize doesn't fight the ScrollView; if so, coordinate into a single gesture or gate the arming region.

### 5. Naming

- **MicButton/PrimaryButton/SecondaryButton are dead legacy components whose names collide with the live Hangs* set — an active edit trap (test comments already say "PrimaryButton" while views render HangsPrimaryButton), and MicButtonInspectorTests keeps dead code green for false confidence** — `apps/ios-app/Hangs/Hangs/Views/Components/MicButton.swift:11` — delete them with the dimension-6 sweep (or rename Legacy* if kept), including MicButtonInspectorTests.swift.

### 6. File & project structure

- **The entire pre-redesign Views/Components/ layer is dead production code: 13 files (ScoreCard, StatsCard, SettingRow, AppLogo, CategoryBadge, LevelBadge, MicButton, ProgressBadge, ProgressBarView, ResultBadge, TrophyIcon, PrimaryButton, SecondaryButton) with zero app-target call sites, plus dead Views/ files LanguagePickerView (still on deprecated NavigationView) and AudioRoutePickerWrapper/AudioRoutePickerButton, and two dedicated test files exercising only dead code** — `apps/ios-app/Hangs/Hangs/Views/Components/ScoreCard.swift:11` — delete in one sweep (git history is the safety net) incl. MicButtonInspectorTests/ProgressBarViewInspectorTests; check the #104 — Media Mode mic-picker decision before removing AudioRoutePickerWrapper.
- **Utilities/ is a junk drawer spanning the DI container (AppState), voice-command domain logic, DEBUG UI-test infra, and the whole theming system — nobody looking for the dependency container would check "Utilities"** — `apps/ios-app/Hangs/Hangs/Utilities/AppState.swift:14` — move AppState to App/ (or DI/), voice-command files to Services/VoiceCommand/, Theme family to Theme/; leave Utilities/ for dependency-free helpers.
- **The QuizViewModel+*.swift split is file-partitioning, not decomposition: state is deliberately non-private so sibling files can reach in (three properties carry explicit "internal for …" comments) — no encapsulation boundary exists between the pieces** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:134` — extract cohesive sub-objects QuizViewModel composes and delegates to, instead of one shared mutable-state bag across six files.
- **Test doubles ship in the production target with inconsistent gating: AppState's ungated "For testing" initializer defaults to MockPackOrderService(), forcing that mock (and MockEarconPlayer, unjustified) to compile into release** — `apps/ios-app/Hangs/Hangs/Utilities/AppState.swift:161` — gate the test initializer with #if DEBUG (previews are DEBUG-only anyway), then gate the remaining two mocks like the other six.
- **Two unrelated "Configuration" directories exist (project-level: 12 .xcconfig files; app-target Hangs/Configuration/: only Hangs.storekit), inviting edits in the wrong one** — `apps/ios-app/Hangs/Hangs.xcodeproj/project.pbxproj:50` — rename the app-target folder (e.g. Hangs/StoreKit/).

### 7. Size & single responsibility

*QuizViewModel (3,017 lines: main 1519, +Recording 697, +Audio 305, +Timers 219, +CommandListener 203, +ScenePhase 74) is the top finding here — merged into dimension 1. Concrete split: RecordingCoordinator, VoiceCommandCoordinator, QuizTimersController, EntitlementReconciler (reconcileEntitlements/syncEntitlementsWithRetry at QuizViewModel.swift:806/827/863), leaving a thin state-machine façade.*

- **AudioService conflates session config/routing/interruptions, input-device management, batch M4A recording, streaming PCM recording, and AVPlayer playback+stall-handling in one 1,246-line class** — `apps/ios-app/Hangs/Hangs/Services/AudioService.swift:71` — split into AudioSessionManager, AudioDeviceManager, BatchRecorder, StreamingPCMRecorder, AudioPlaybackService behind the existing protocol facade.
- **AuthService bundles token bootstrap/refresh, App Attest, Apple Sign-In completion, account-management endpoints, and an embedded KeychainTokenStore type in one 823-line file** — `apps/ios-app/Hangs/Hangs/Services/AuthService.swift:112` — move KeychainTokenStore to its own file; extract Apple Sign-In + account management into an AccountManagementService depending on the core token actor.
- **SettingsView renders 8 settings domains plus a DEBUG group in one monolithic view with embedded account logic** — `apps/ios-app/Hangs/Hangs/Views/SettingsView.swift:447` — promote each groupSection to its own subview; the auth-logic extraction is the dimension-1 AccountViewModel.
- **NetworkService's 12 endpoint methods hand-duplicate the same authorized-request → guard → error-decode pipeline (12 copies of the HTTPURLResponse guard; the 429/quota branch copied verbatim at lines 225/395/458)** — `apps/ios-app/Hangs/Hangs/Services/NetworkService.swift:220` — extract one generic `performRequest<T: Decodable>` (auth, breadcrumb, 429 parsing, decode).
- **SilenceDetectionService couples speech-auth/asset bootstrapping, AVAudioEngine tap/conversion plumbing, the VAD state machine, and command relay in one 589-line class** — `apps/ios-app/Hangs/Hangs/Services/SilenceDetectionService.swift:91` — split out a VoiceAssetBootstrapper and an AudioEnginePipeline; keep only VAD + relay.
- **startNewQuiz is a 134-line function whose inline quota/429 catch branch duplicates handleError's resync/paywall logic nearly verbatim (copies already diverged in user-facing copy)** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:549` — route the catch through the existing handleError helper.
- **submitVoiceAnswer spans 128 lines with 6 inline error branches, each with its own MainActor.run block; the quota branch is a third copy of the resync/paywall logic** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel+Recording.swift:344` — extract each catch branch into a named handle<X>Failure(), mirroring handleTranscriptionFailure.
- **handleQuizResponse is a 125-line function mixing validation, score/stats/history updates, state transition, TTL extension, and feedback-audio kickoff** — `apps/ios-app/Hangs/Hangs/ViewModels/QuizViewModel.swift:1214` — extract stats/history apply and TTL fire-and-forget into small helpers.
- **startStreamingRecording is 133 lines mixing hardware-format retry wait, engine/converter construction, and an inline tap-conversion closure** — `apps/ios-app/Hangs/Hangs/Services/AudioService.swift:794` — extract a private makeStreamingEngine(...) helper.

### 8. iOS standards & concurrency

Audit result: **clean.** 0 nonisolated(unsafe), 0 @unchecked Sendable, 0 Task.detached, 0 DispatchSemaphore; all ~60 `nonisolated` uses justified; @preconcurrency imports cited; timers on the main run loop; every VM/service @MainActor or an actor; app target genuinely builds Swift 6 + strict complete + MainActor default.

- **HangsTests/HangsUITests pin SWIFT_VERSION = 5.0 (their xcconfigs never include Shared.xcconfig), so all test code compiles without Sendable checking or MainActor default — contradicting the documented Swift 6 standard and leaving concurrency misuse in tests (e.g. the known flaky async voice tests) uncaught** — `apps/ios-app/Hangs/Hangs.xcodeproj/project.pbxproj:427` — make the test xcconfigs include Shared.xcconfig and delete the 12 explicit SWIFT_VERSION = 5.0 overrides.

#### Deployment target: raise 18.0 → 26.0

The entire availability surface is two guards: `@available(iOS 26,*)` in SilenceDetectionService.swift:89 and the wiring check in AppState.swift:81. There is **no legacy speech fallback** — sub-26 silently loses VAD/barge-in/voice commands, an untested product-degrading path. Raising the target (`apps/ios-app/Hangs/Hangs/Configuration/../Shared.xcconfig:42` project-level, plus the test-target 18.0 overrides in project.pbxproj) deletes both guards, makes SilenceDetectionServiceProtocol non-optional (~15 nil-branches removed across QuizViewModel/+Audio/+Recording/+CommandListener/AppState), and guarantees SpeechAnalyzer everywhere. Cost: excludes only pre-iPhone-11 hardware — irrelevant with zero real users and an iOS 26 founder device. **Recommendation: raise now, folding in the test-xcconfig unification above in the same change.**

### 9. Adjacent: errors, dead code, logging, testability

- **AuthService (823 lines) has zero Sentry integration — critical auth events (e.g. a dropped signed-in session) reach only local os.Logger, invisible to production monitoring, while every peer service routes through SentryLog** — `apps/ios-app/Hangs/Hangs/Services/AuthService.swift:350` — route warning/error-level auth events through SentryLog (.network category exists) so TestFlight auth incidents are queryable via /check-crashes.

*(All dead-code findings — PrimaryButton/SecondaryButton, TrophyIcon, the CategoryBadge/LevelBadge/… cluster, LanguagePickerView, AudioRoutePickerWrapper — merged into the dimension-6 sweep.)*

## Top 10 recommendations

1. **Enforce the state machine on its broken paths** — guard startNewQuiz + single-flight, guard the skip-undo expiry on quizState, clear isMinimized on .finished, single-owner MCQ selection (`QuizViewModel.swift:555/1069/1379`, `MCQOptionPicker.swift:44`). Real correctness bugs in the driving loop.
2. **Decompose QuizViewModel** into RecordingCoordinator / VoiceCommandCoordinator / QuizTimersController / EntitlementReconciler with real encapsulation, and fold phase-scoped @Published clusters into QuizState associated values / sub-structs (`ViewModels/QuizViewModel*.swift`).
3. **Own navigation as state**: NavigationPath/route enum cleared where quizState leaves idle; delete the .packQuizStarted notification + navStackID reset; fixes the voice-"start"-over-pushed-stack bug (`ContentView.swift:186`, `QuizViewModel+CommandListener.swift:169`).
4. **Extract AccountViewModel** for the SIWA/sign-out/delete/export flow shared by SettingsView + ContextualSignInSheet; add isSignedIn to AuthServiceProtocol and delete all five ad hoc KeychainTokenStore() reads (`SettingsView.swift:114/460`, `ContextualSignInSheet.swift:201`, `ContentView.swift:196`).
5. **Raise deployment target to iOS 26.0 and unify test targets onto Swift 6 strict** in one xcconfig change (`Shared.xcconfig:42`, `project.pbxproj:427`) — deletes the untested sub-26 degraded path and ~15 nil-branches.
6. **One dead-code sweep**: 13 Views/Components files + LanguagePickerView + dead inspector tests; check #104 — Media Mode before removing AudioRoutePickerWrapper.
7. **Split AudioService** into session/device/batch/streaming/playback units behind the existing protocol (`Services/AudioService.swift:71`).
8. **Introduce PaywallViewModel** so purchase orchestration leaves the revenue-critical View (`Views/PaywallView.swift:27`).
9. **De-duplicate the quota/429 + resync/paywall logic** (3 diverged copies) through one handleError path, and extract NetworkService's generic performRequest (`QuizViewModel.swift:646`, `+Recording.swift:410`, `NetworkService.swift:220`).
10. **Wire AuthService through SentryLog** so auth incidents are visible in production monitoring (`Services/AuthService.swift:350`).

## Target architecture

Checkable rules for all future iOS work:

**State**
- QuizState (with associated values) is the *only* source of phase truth; every transition goes through `transition(to:)` and every caller handles a rejected transition — no "keep working out-of-state".
- Phase-scoped state lives in the phase (associated value or sub-struct), never as free @Published vars reset by hand; leaving a phase drops its state atomically.
- A rendered value is either @Published or computed from @Published — no non-observable vars feeding the view tree.
- One state machine per axis: CommandCapturePhase is either fully wired or gone.

**ViewModels & DI**
- Every screen with behavior binds to a ViewModel; Views hold presentation @State only — no service calls, no Keychain reads, no purchase orchestration in a View.
- All services reach views exclusively through AppState-injected protocols; constructing a service/store inline in a View is a review-blocker. Test initializers and mocks are #if DEBUG.
- AppState is a pure DI container: no weak back-registrations; cross-cutting events (scenePhase, purchase success) flow through an explicit subscribed object.

**Navigation**
- Navigation is observable state (route enum / NavigationPath) owned by one object; no NotificationCenter broadcasts, no `.id()` identity resets for navigation.

**Size & structure**
- Files ≤ ~300 lines; a type that needs `+Extension` files with "internal for sibling" members must instead compose sub-objects with private state.
- One screen per file in Views/; components live in one live design-system folder; dead code is deleted the same session it becomes dead.
- Groups by role: App/ (composition root, DI), Services/ (incl. VoiceCommand/), Theme/, Utilities/ only for dependency-free helpers.

**Concurrency & platform**
- Deployment target iOS 26.0; app *and test* targets build Swift 6 + strict complete + MainActor default via Shared.xcconfig.
- Standing bans hold: no nonisolated(unsafe), no @unchecked Sendable, no Task.detached; `nonisolated` only with a documented rationale and a hop back via Task { @MainActor }.
- Every service logs warning/error-level events through SentryLog, not os.Logger alone.