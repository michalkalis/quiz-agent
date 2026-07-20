# Issue 111: Navigation as owned state (pack-nav broadcast + voice-"start" bypass)

**Triage:** bug · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 3. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 3 + dimension 4 (navigation). Link, don't restate.

## Why

Navigation is split across two incompatible models — a `quizState`-keyed root swap and a real `NavigationStack` push chain — bridged at runtime by a hidden `NotificationCenter` broadcast. One driving-loop bug already ships through the gap and a second is latent:

1. **Voice "start" over a pushed stack (shipping bug).** The "start" command calls `startNewQuiz()` directly and never fires the `.packQuizStarted` teardown, so saying "start" while Settings/OrderPack/MyPacks is pushed leaves that screen covering the fresh QuestionView (`QuizViewModel+CommandListener.swift:169`). Error-retry (`ContentView.swift:298`) shares the same latent gap.
2. **Broadcast + identity-reset bridge (latent + unmaintainable).** ContentView tears the stack down by force-recreating its identity (`navStackID = UUID()` + `.id()`) on a `.packQuizStarted` broadcast fired from one call site (`SettingsView.swift:647`). Hidden global coupling: a new listener, a second post site, or an ordering change silently breaks the #95 — custom quiz packs flow, and the mechanism is invisible to anyone reading either end alone (`ContentView.swift:186`).

Maintainability cost: 9 `startNewQuiz` call sites must each remember to pair a teardown — only 1 does — and the coupling is un-unit-testable (nav is view-level `@State`). Target rule (review dim. 4 / Top-10 item 3, [source](../research/ios-architecture-review-2026-07-18.md)): navigation is observable state owned by one object, cleared where `quizState` leaves idle — no broadcasts, no `.id()` resets.

## Scope

**In:**
- One owned route object holding the pushed-stack path (route enum / `NavigationPath`), replacing the `.packQuizStarted` broadcast + `navStackID` identity reset.
- A single teardown path all 9 `startNewQuiz` call sites converge on (incl. voice + error-retry), clearing the stack on every quiz-start.
- Migrate the 4 NavigationLinks + 1 `navigationDestination` on the single root stack (`ContentView.swift:77`) to path/route-driven pushes — the minimum for a complete, clearable teardown.
- New RS regression scenario + a unit seam on the owned route object.

**Out:**
- Sheet hosts (paywall, sign-in, mic picker, answer-confirm, quiz-settings, onboarding cover) and the `MinimizedQuizView` overlay — not on the nav stack.
- Self-contained sheet stacks (AudioDevicePicker, SourceWebView) — leave alone.
- Dead `LanguagePickerView` removal → #115 — iOS 26 target / dead-code sweep.
- QuizViewModel decomposition → #113 — QuizViewModel decomposition. Any visual redesign.

## Resolved design decisions

1. **Route owner — a small `NavigationModel` owned at ContentView, not QuizViewModel.** New `NavigationModel: ObservableObject` holding the pushed path (`NavigationPath` over an `AppRoute` enum: `.settings / .orderPack / .myPacks / .orderProgress`, + DEBUG `.debugLog`), created as `@StateObject` in ContentView (which already hosts the `NavigationStack`) and injected via `@EnvironmentObject`. *Why here:* the root swap stays `quizState`-driven on QuizViewModel; only the push chain needs an owner. Putting it on QuizViewModel fattens the god object #113 — QuizViewModel decomposition is shrinking; burying it in AppState overloads the service locator the review already flags (zero-`@Published` DI container). A standalone object *is* the "one object owns navigation" rule, and is exactly what #97 — CarPlay support's second scene can later observe — without building for CarPlay now.
2. **Teardown — reactive clear on the `quizState`→active transition, at the ContentView layer.** ContentView clears `NavigationModel.path` when `quizState` leaves `.idle` (enters `.startingQuiz`) — the same idiom as the existing root-content switch and `screenAwakeWriter` apply (research §134-145). *Why not the two framed options:* putting it inside `startNewQuiz()` forces a VM→nav back-reference — the exact AppState-weak-ref coupling #113 removes — and only covers imperative callers; a wrapper every call site routes through needs 9 edits and a 10th site can forget it. Driving off the state transition every `startNewQuiz` already produces makes it structurally impossible to start a quiz without tearing the stack down — precisely the `CmdListener:169` bypass, fixed for free, for voice and error-retry alike. (Error-retry's `error→startingQuiz` transition being currently rejected is a separate state-machine finding, not this issue; once it lands it enters `.startingQuiz` and inherits the clear.)
3. **Migration breadth — full within the one root stack, nothing beyond it.** All 5 pushes on `ContentView.swift:77`'s stack (Home→Settings, Settings→OrderPack, Settings→MyPacks, Settings→DebugLog, OrderPack→OrderProgress) move to path/route-driven. *Why full, not partial:* they share one `NavigationStack`; a half-migrated stack leaves old-style pushes the path can't clear, so teardown is incomplete and the bug returns — full migration of *this stack* is the minimum for correctness, not over-abstraction. *Why not broader:* self-contained sheet stacks and dead `LanguagePickerView` stay untouched (Minimal Footprint / simple-and-robust bar). DebugLog is DEBUG-only — folded into the sweep for consistency, not load-bearing. No multi-scene / CarPlay route coordinator now — the single `NavigationModel` extends to #97 without speculative abstraction.
4. **Test strategy — new RS + unit seam on the route object.** (a) End-to-end `RS-pack-nav-start` (`testRSPackNavStart` in `HangsUITests/Regression/RegressionTests.swift`): push Settings→OrderPack, fire "start" via both the CTA and the voice HTTP-listener path, assert QuestionView is the visible root with no Settings covering it — the regression that would have caught the bypass; needs a new Settings/OrderPack page object (current page objects are Home/Paywall/Question/Result only). (b) Unit test on `NavigationModel`: seed a non-empty path, drive `quizState` idle→`.startingQuiz`, assert the path empties — the bypass-proof property, now assertable off-sim because nav is an owned observable (was un-assertable view-level `@State`).

**Founder decision needed (non-blocking).** After a pack quiz starts, tearing the stack down means post-quiz Completion / "Back" lands on **Home**, not back in **MyPacks**. Default recorded: **reset to Home** — preserves current shipped behavior (bug-preserving) and is trivially reversible later (re-push MyPacks onto the cleared path on `.finished`). The plan executes on this default; do **not** block. Confirm interactively when convenient.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ✅ done | — |
| 2 · Plan              | ✅ done | — |
| 3 · Plan review       | ⬜ pending | ready-check — · design-soundness — |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 11:41 · **Next:** Phase 3 (dual gate) · **Gate attempts:** P3 0/3 · P5 0/3

## Research (Phase 1, 2026-07-20)

**Anchors — all confirmed, no drift.** `QuizViewModel+CommandListener.swift:169` (`case (.home, .start)` → direct `startNewQuiz()`, no broadcast); `ContentView.swift:186` (`.onReceive(.packQuizStarted)` → `navStackID = UUID()`; `navStackID` @State :30, `.id(navStackID)` :118); `SettingsView.swift` `playPack` func :646, broadcast post :647, `startNewQuiz(packId:)` :648 — the **only** call site that fires the broadcast.

**Navigation surface**
- **1 real root stack:** `ContentView.swift:77` NavigationStack, root content = 6-branch `quizState` switch (:79 idle→Home; startingQuiz/asking/recording/processing/skipping→Question|Home-if-minimized; showingResult→Result|Home; finished→Completion; error→ErrorView). This is the "root swap" model.
- **Push chain (4 NavigationLinks + 1 destination) on that stack:** Home:18→Settings; Settings:617→OrderPack, :627→MyPacks, :679→DebugLog(DEBUG); OrderPack:55 `navigationDestination(isPresented:$showProgress)`→OrderProgress. Deep flow = Home→Settings→OrderPack→OrderProgress **or** Home→Settings→MyPacks. `#95` pack-play lives here.
- **9 `startNewQuiz` sites; only 1 pairs the teardown:** Home:64, Completion:177, ContentView:298 (Error retry), CmdListener:169 (voice — the bypass), internal QuizViewModel.swift:894/1124/1195, def :549 — **none** post `.packQuizStarted`; only SettingsView:648 does. Safe from Home (nothing pushed); the voice + error paths are latent bugs if a stack is ever pushed.
- **Nav notifications = exactly 1:** `.packQuizStarted` (def ContentView:334, post SettingsView:647, obs ContentView:186). All other NotificationCenter use is non-nav (auth-dropped, AudioService route/interruption).
- **Self-contained stacks NOT in the chain (leave alone):** AudioDevicePickerView:16 (sheet from Home:81/Settings:148); SourceWebView:17 & LanguagePickerView:15 (`NavigationView`, latter is dead code, dim-6 sweep); OrderProgress/Home/Settings/DebugLog `:130/:355/:728/:255` are `#Preview` wrappers.

**Must preserve:** the deep pushed chain + its teardown on quiz-start from *every* entry point (incl. voice); the 6-state root swap; the floating `MinimizedQuizView` overlay (ContentView:121, driven by `isMinimized`, not nav); sheet hosts (paywall :152, sign-in :164, mic picker, answer-confirm QuestionView:52, quiz-settings :69, onboarding-replay cover :146); `screenAwakeWriter` apply/reset tied to quizState+isMinimized (:134-145).

**Test / verification seams:** No automated test exercises the teardown / `.packQuizStarted` / voice-start-over-pushed-stack (grep clean). RS scenarios (`HangsUITests/Regression/RegressionTests.swift`: Start/Correct/Incorrect/LongQuestion/Paywall) all launch from Home — none from a pushed pack stack; page objects are Home/Paywall/Question/Result only (no Settings/Pack page). Sim-driving idiom: `/regression` skill via XcodeBuildMCP + curl HTTP listener (`Support/UITestClient.swift`) + `--ui-test-*` DEBUG launch args, delegated to `ios-ui-driver`. **Acceptance can name a concrete new RS:** push Settings→OrderPack, fire "start" (voice + button), assert QuestionView is the visible root with no Settings covering it. Unit seam: nav is view-level `@State` (navStackID) today — un-assertable; moving it to an owned observable route object makes it ViewInspector/unit-testable (a stated win).

**Build-vs-adopt: BUILD native, no dependency.** Target = owned `NavigationPath`/route enum on one object, cleared where `quizState` leaves idle. In-repo precedent already exists: (a) the `quizState`-keyed root switch (ContentView:79) is navigation-as-observable-state for the root, and (b) `navigationDestination(isPresented:)` (OrderPack:55) is the closest owned/state-driven push — the refactor *generalises* these into a path/enum, not a new pattern. Matches repo rule "default to native over custom" (memory `feedback_native_back_gesture`); no SPM router to adopt (`NavigationStack(path:)` is the native tool).

**Web pass skipped:** owned NavigationPath/route-enum is Apple-native and well-documented; no open external unknown.

**Product question (minor, for Phase 2):** after a pack quiz starts the pushed Settings→OrderPack chain is torn down, so post-quiz "Back"/Completion lands on Home, not back in MyPacks — this matches current shipped behavior (bug-preserving default), but confirm the founder wants pack-play to reset to Home vs. return to the pack list.
