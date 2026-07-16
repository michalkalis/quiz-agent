# #97 — CarPlay support

**Triage:** enhancement · planned
**Status:** Planned 2026-07-16 (founder HIGH priority, post-MVP). MVP (#96 — iOS MVP completion) must stay stable: CarPlay code must be mechanically unable to reach mainline TestFlight builds until deliberately enabled in Phase 6.

## Why

The product is voice-first trivia while driving; the driver's real surface is the car head unit. A native, audio-first CarPlay presence is competitive white space — Apple blocks screen-based games from CarPlay, so an approved voice experience occupies a surface competitors legally cannot (see `docs/research/competitive-analysis-voice-driving-trivia-2026-06-27.md`).

## Research

Full findings, claim-verification table, and sources: `docs/research/carplay-support-research-2026-07-16.md`. Do not restate here. Load-bearing conclusions:

- Only viable entitlement: **Voice-Based Conversational** (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+). No games/trivia category exists; games are excluded from CarPlay platform-wide. Approval for a "trivia game" as-pitched was adversarially **refuted** — the request must be framed as a hands-free voice companion, and rejection is a live outcome the plan must survive.
- Entitlement review has **no SLA** (days to many months, silence common). All agent phases below are sequenced to never block on Apple.
- CarPlay is a second UIScene in the **same binary** — isolation must be build-time, not "separate app".
- Car-mic STT quality/echo is **unverified** (verdict: uncertain) and only testable in a physical car; fallback design = phone mic stays input, CarPlay handles output/UI.
- Audio already routes to car speakers today with zero entitlement — the guaranteed fallback product if Apple says no.

## Locked decisions

| Decision | Choice | Rejected alternatives |
|---|---|---|
| Entitlement path | Voice-Based Conversational, pitched as hands-free voice companion (founder wording gate in Phase 1). Fallback: keep today's zero-entitlement audio passthrough; tertiary: evaluate Audio-category Now-Playing display only if denied. | Driving Task (utility-only scope, weakest depth caps); Audio as primary (continuous-playback model, no interactive Q&A) |
| MVP isolation | Compile-flag + dedicated build config/scheme (extends the proven `apps/ios-app/Hangs/Configuration/*.xcconfig` composition), **plus** entitlement withheld from `Hangs-Prod.entitlements` / the match AppStore profile as an independent second safety layer — even leaked code cannot activate CarPlay without the entitlement. One line: it reuses this repo's exact existing mechanism, keeps work on main per the no-gitflow convention, and the release lane (`fastlane/Gymfile` pinned to Hangs-Prod/Release-Prod, match readonly) mechanically cannot pick it up. | Long-lived feature branch (violates `.claude/rules/shared.md` git workflow; zero CI on non-main branches; `ios-release.yml` can be pointed at any ref, so branch isolation is process-only); entitlement-withholding alone (insufficient for development) |

## Phases

Phases 0 and 2 are MVP-safe and land on main normally. Phase 1 starts immediately — it needs nothing from Phase 0 — and runs fully in parallel with everything. Phases 3–5.1 are simulator-scoped and independent of the Apple wait. Phases 5.2 and 6 gate on the entitlement grant.

### Phase 0 — MVP isolation scaffolding (agent)

- Add a `CARPLAY` value to `SWIFT_ACTIVE_COMPILATION_CONDITIONS` via a new `CarPlay.xcconfig` axis; create `Debug-Local-CarPlay` (composition of existing Debug + Local + new CarPlay layer) and a shared scheme `Hangs-CarPlay-Dev`.
- Make the CarPlay scene-manifest Info.plist entry (`CPTemplateApplicationSceneSessionRoleApplication`) **config-scoped** via a per-config `INFOPLIST_FILE` override: the CarPlay xcconfig layer points at a new `Info-CarPlay.plist` carrying the full scene manifest (phone scene + `CPTemplateApplicationSceneSessionRoleApplication` + `UIApplicationSupportsMultipleScenes = YES`). Known interaction: `Shared.xcconfig` sets `INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES`, and a file-declared `UIApplicationSceneManifest` supersedes that generation — so the CarPlay plist must declare the phone scene explicitly, not just the CarPlay one. No `INFOPLIST_KEY_*` single-value setting can express the nested scene dictionary; don't attempt that route. Gating only the Swift side while leaving a static manifest entry is the sharpest crash risk in this plan.
- Add a repeatable **isolation guard**: a script (runnable locally and as a CI step) that builds Release-Prod and asserts (a) the built Info.plist contains no `CPTemplateApplicationSceneSessionRoleApplication`, and (b) the binary contains no CarPlay symbols (e.g. `nm`/`strings` finds no `CPTemplateApplicationSceneDelegate`). This guard is **not deferrable** and is re-run as a done-criterion in Phases 3 and 4.
- Add a third entitlements file (`Hangs-CarPlay-Dev.entitlements`: Apple Sign-In + the CarPlay key) used only by the CarPlay config. `Hangs-Local.entitlements` and `Hangs-Prod.entitlements` stay untouched.
- CI: extend `.github/workflows/ios-ci.yml` with a build-only job for `Hangs-CarPlay-Dev` (or record an explicit written deferral — the deferral option applies only to this build job, never to the Release-Prod isolation guard above) — today only `Hangs-Local` gets CI, so CarPlay work would otherwise accumulate uncompiled.

**Done when:** the isolation guard passes and is committed as a repeatable script/CI step (Release-Prod build: no CarPlay scene entry in the built Info.plist, no CARPLAY-gated symbols in the binary); `Hangs-Prod`/`Hangs-Local` schemes build unchanged; Gymfile still references only Hangs-Prod/Release-Prod; CI decision committed.

### Phase 1 — [HUMAN] entitlement request (starts immediately, fully parallel with Phase 0)

- (agent) First action of this issue, before any Phase 0 work: draft the justification text for founder review. Nothing here depends on Phase 0 — the bundle ID exists and the app is already a shipped TestFlight product.
- [HUMAN] Founder decides the pitch framing (product decision): hands-free voice companion wording, category Voice-Based Conversational — informed by a manual read of the June 2026 CarPlay Developer Guide PDF (research open question 5).
- [HUMAN] Founder files the request at developer.apple.com/contact/carplay/ from the **company Apple Developer account** (team KAGWHPZZFQ): bundle `com.missinghue.hangs`, single category, safety justification.
- Track outcome in this issue. No agent phase waits on this. If rejected → Kill/fallback section.

**Done when:** request filed and confirmation recorded; outcome (grant / rejection / silence) logged when known.

### Phase 2 — prerequisite refactors on main (agent; MVP-safe, no CarPlay code)

Plain refactors, valuable regardless of CarPlay, shipped behind the existing test suite:

- 2.1 Promote QuizViewModel ownership: `AppState` owns a non-optional, app-lifetime instance created in its init; `ContentView` consumes it instead of calling `makeQuizViewModel()` (files: `apps/ios-app/Hangs/Hangs/Utilities/AppState.swift`, `ContentView.swift`). Without this, a CarPlay scene would spawn a second, divergent quiz session. **Done:** ContentView no longer constructs the view model; full unit suite + targeted RS regression subset green; one TestFlight-eligible commit.
- 2.2 Scene-phase mic teardown rework (`QuizViewModel+ScenePhase.swift`): distinguish "phone scene backgrounded while another scene is active" from "no active scene". **Done:** unit test proves a simulated phone-lock during an active non-phone-scene session does not tear down the listening loop.
- 2.3 Voice-command taxonomy audit (`QuizViewModel+CommandListener.swift`): enumerate the mapping of planned CarPlay surfaces onto `.home/.question/.confirmation/.result`; extend `VoiceCommandScreen` only if the mapping demands it. **Done:** mapping table committed in this issue file.

### Phase 3 — audio-first CarPlay loop (agent; behind CARPLAY flag)

- First step: **verify the simulator assumption** — CarPlay templates should render in the Xcode CarPlay simulator with the entitlement key only in the local entitlements file (no Apple grant; simulator does not validate provisioning). If false, stop and escalate: sequencing changes because pre-grant development would be blocked.
- Decide OS-availability gating: the app's deployment target is iOS 18.0 (`Shared.xcconfig`) while the voice-conversational entitlement and its behavior are iOS 26.4+. Either mark the scene delegate and all new 26.4+ API use `@available(iOS 26.4, *)`, or raise `IPHONEOS_DEPLOYMENT_TARGET` in the CarPlay xcconfig layer only — record the choice and rationale in this issue.
- Implement the gated scene delegate (CPTemplateApplicationSceneDelegate) with `CPVoiceControlTemplate` as root: speaking state (existing pre-cached TTS playback via AudioService) alternating with listening state (existing SpeechAnalyzer answer capture), driving the shared QuizViewModel from Phase 2.
- Conform the audio-session lifecycle to category rules: session active only during voice interaction; measure the latency cost of activate/deactivate per turn against today's continuously-open session (research open question 6).

**Done when:** a full quiz loop (start → question TTS → voice answer → evaluation → next → finished) runs end-to-end in the CarPlay simulator window with the phone UI never touched, and locking the phone mid-quiz does not kill the loop; the Phase 0 isolation guard is still green (Release-Prod stays free of the scene entry and CARPLAY symbols).

### Phase 4 — templated UI within the 3-level cap (agent)

- Template tree: root voice template + at most two more levels (quiz-pack/topic selection list, result/score surface). Query `CPListTemplate.maximumItemCount` at runtime; design for a single-digit worst case.
- Wire voice commands (#77 — voice commands heritage: repeat, skip, next) through the Phase 2.3 mapping so they work in the CarPlay context.

**Done when:** template depth never exceeds 3 including root; list content clamps to runtime limits; commands verified in simulator; the Phase 0 isolation guard is still green.

### Phase 5 — testing

- 5.1 (agent) CarPlay regression scenarios, documented as RS-CP-01.. in `docs/testing/runs/`, split by rig:
  - **Sim-verifiable** (Xcode CarPlay simulator display; plus the standalone CarPlay Simulator.app against a real iPhone on `mba` if a device is available): connect/disconnect mid-quiz, locked-phone connect, backgrounded-phone session survival.
  - **Not sim-triggerable** — audio interruptions (navigation prompt, Siri, phone call): agent-verifiable proxy = unit/integration tests injecting `AVAudioSession` interruption notifications; the real-world versions of these scenarios move to the 5.2 [HUMAN] physical checklist.
  - Every RS-CP run report must state which rig each scenario ran on — fail loud; a scenario whose rig is unavailable is reported as not-run, never silently passed.
- 5.2 [HUMAN] Physical head-unit validation (requires entitlement grant on a development profile): founder tests in a real car — car-mic recognition accuracy vs phone mic, TTS echo bleeding into answer capture, Bluetooth HFP narrowband impact, plus the real audio-interruption scenarios handed over from 5.1 (navigation prompt, Siri, phone call). This is the make-or-break check simulators cannot perform. **Decision recorded:** car-mic input viable, or fallback = phone mic stays input while CarPlay handles output/UI (then agent implements that routing variant as a follow-up task).

**Done when:** all agent-verifiable 5.1 scenarios (sim runs + interruption-injection tests) pass and are filed with per-scenario rig recorded; 5.2 verdict + decision recorded in this issue.

### Phase 6 — release enablement (gates: entitlement granted + Phase 5 passed)

- 6.1 [HUMAN] Founder approves the match AppStore profile regeneration in hangs-certs (non-readonly bootstrap run). Caution: this touches the shared distribution cert behind every mainline TestFlight build — follow the procedure in memory `project_ios_capability_profile_regen`; mis-run risks Release-Prod signing app-wide.
- 6.2 (agent) Add the CarPlay entitlement to `Hangs-Prod.entitlements`, enable CARPLAY + the scene manifest for Release-Prod, cut a TestFlight build via the existing fastlane beta lane, smoke-test.
- 6.3 [HUMAN] Founder decides App Review submission timing and reviews the review-notes text (extra CarPlay review scrutiny expected).

**Done when:** a TestFlight build with CarPlay active runs on the founder's head unit; a pre-iOS-26.4 device or simulator confirms graceful degradation (no CarPlay surface, today's audio passthrough unchanged, no crash on head-unit connect); App Review outcome logged.

## Kill / fallback criteria

- **Apple rejects the entitlement:** Phases 0–5.1 output stays parked behind the CARPLAY flag on main (compiled out of every release); product remains today's audio-passthrough experience. Founder may choose one re-file with revised framing, or evaluate the Audio-category Now-Playing fallback as a separate scoped decision. No sunk work leaks to users.
- **Car-mic STT unacceptable (5.2):** switch to the phone-mic-input hybrid; do not ship a degraded listening loop.
- **Prolonged Apple silence:** not a blocker by construction — everything except 5.2/6 completes without the grant; the issue simply pauses at a clean boundary with a handoff note.

## Top risks (full list in research doc)

1. Discretionary entitlement approval — HIGH rejection risk for anything smelling like a game; mitigated by framing, parallel sequencing, and the passthrough fallback.
2. Ungated scene-manifest entry in a release build = crash risk on head-unit connect; mitigated by the Phase 0 config-scoped manifest + the repeatable isolation guard, re-verified as a done-criterion in Phases 3 and 4.
3. Car-mic STT/echo unverified (adversarial verdict: uncertain); mitigated by the 5.2 gate and hybrid fallback.
4. Match profile regen touches the shared distribution cert; mitigated by founder gate 6.1 and the documented procedure.

## Links

- Research: `docs/research/carplay-support-research-2026-07-16.md`
- Competitive white space: `docs/research/competitive-analysis-voice-driving-trivia-2026-06-27.md`
- Voice stack: #77 — voice commands · #45 — iOS MCQ voice + redesign
- MVP stability constraint: #96 — iOS MVP completion
