# Issue #92 — Rename app: Hangs → Trubbo (display/brand rename; identifiers stay)

**Triage:** enhancement · ready-for-agent (session-split)

**Created:** 2026-07-07 · **Source:** founder decision 2026-07-07 ("nazov appky sa zmenil na trubbo")

**How to run:** each session below = one fresh Opus session. Prompt: *"Execute Session N of #92 — rename Hangs → Trubbo (`docs/issues/issue-92-rename-trubbo.md`). Read the locked decisions first."* Sessions 1–2 are order-independent; Session 3 last. The [HUMAN] ASC step can (and ideally should) run first — it is the name-availability gate.

## Scope & locked decisions

User-facing name becomes **Trubbo**. Everything else was judged 2026-07-07 against a full code inventory (Explore pass, this session):

| Surface | Call | Why |
|---|---|---|
| Bundle ID `com.missinghue.hangs` | **KEEP** | Founder's instinct confirmed. Invisible to users. Changing it = brand-new App Store Connect app record (TestFlight testers + build history lost), match certs/profiles regenerated, Sign in with Apple entitlement re-setup, on-device Keychain/UserDefaults wiped. Zero user benefit. Precedent: CarQuiz-era identifiers were deliberately kept at the previous rename (CONTEXT.md). |
| Xcode target/module/schemes/folders `Hangs*`, `Theme.Hangs` + `Hangs*` component namespace (~900 internal hits) | **KEEP** | Internal only; renaming breaks CI workflows, fastlane, `/regression`, mba automation — for no user-visible value. |
| Sentry slug `missinghue/carquiz` · StoreKit ID `com.carquiz.unlimited` · URL scheme `hangs-test://` · logger subsystem · Fly app names | **KEEP** | Stable identifiers rule from the CarQuiz→Hangs rename (CONTEXT.md:14,136) — renaming breaks alert routing / purchase continuity for nothing. |
| App icon / logo artwork | **OUT OF SCOPE** | Separate branding decision for the founder; current icon ships until decided. |
| Historical docs (`docs/issues/`, `docs/handoffs/`, `docs/testing/runs/`, `docs/archive/`) | **KEEP as-is** | History is not rewritten; only living docs change. |
| Backend / admin web titles ("Quiz Agent API", "Quiz Question Manager") | **KEEP** | Never carried the Hangs brand; internal surfaces. No backend work in this issue. |

**Assumption (founder may override):** wordmark keeps its visual style — `hangs.` → `trubbo.` (lowercase + pink dot), hero `HANGS` → `TRUBBO`, tagline "voice-based trivia for the road" unchanged. No TTS speaks the app name and the #77 voice-command word-set is name-free — voice flows untouched.

## Session 1 — iOS in-app rename (Opus)

- [x] `apps/ios-app/Hangs/Configuration/Shared.xcconfig:12` — `APP_DISPLAY_NAME = Trubbo` (Local build auto-becomes "Trubbo Local" via `Local.xcconfig`)
- [x] `apps/ios-app/Hangs/Hangs/Views/Components/Hangs/HangsChrome.swift:20` — wordmark `Text(verbatim: "hangs.")` → `"trubbo."`
- [x] `apps/ios-app/Hangs/Hangs/Views/Components/Hangs/HangsBlocks.swift:342` — hero `title: "HANGS"` → `"TRUBBO"` (DEBUG #Preview; the only HANGS hero — runtime heroes say SETTINGS/COMPLETE, unaffected)
- [x] `Localizable.xcstrings` — the 2 EN source keys containing "Hangs" → "Trubbo" (re-sorted alphabetically); **sk-carry was moot**: main's catalog is en-only, sk lives on the unmerged #56 branch → when merging #56, re-pair its sk rows onto the new Trubbo keys; all 3 comment mentions fixed
- [x] `OnboardingView.swift:51,:99` — correction: keys ARE the code literals, so both literals changed to "Trubbo …" (plan expected no code change)
- [x] Re-record snapshot tests — none needed: no `.txt` snapshot contains the wordmark; updated the one ViewInspector assertion (`HangsSharedPrimitivesTests.swift:30-36` now expects `trubbo.`)
- [x] Verify: build green; targeted suites green (brand row 2, home snapshot 1, status bar 2, onboarding 7 — 12/12 passed); sim visual check 4/4 PASS (springboard "Trubbo Local", wordmark, onboarding texts, Settings clean). NB: sim driving needed explicit `configuration=Debug-Local` — defaults resolved to Release-Prod.

**Session 1 ✅ DONE 2026-07-07.**

## Session 2 — design source + living docs (Opus)

- [ ] `design/quiz-agent.pen` via Pencil MCP: find text nodes `hangs.` / `HANGS` across screens → Trubbo equivalents (same styling). NB: working tree already has uncommitted `.pen` changes — snapshot state first, touch only text nodes.
- [ ] **[HUMAN] end-of-session:** founder opens Pencil and ⌘S-saves the .pen (agent edits don't persist without it — known from #77 task 77.12)
- [ ] `CONTEXT.md:9-14,136` — glossary becomes the rename authority: Trubbo = current name (2026-07-07), Hangs → historical alias (like CarQuiz); extend the keep-identifiers rule with the hangs-era IDs (bundle ID, URL scheme, logger subsystem)
- [ ] `README.md:12` + `docs/product/INDEX.md:14` + `docs/product/prds/mvp-launch.md:1,7` + `docs/product/stories/mvp-user-stories.md:1` — retitle Hangs → Trubbo (living product docs only)
- [ ] `docs/research/app-naming.md` — one-line addendum: renamed to Trubbo, founder decision 2026-07-07
- [ ] Verify: grep whole-word `Hangs` outside historical dirs + internal namespace → every remaining hit is a KEEP-listed identifier

## Session 3 — App Store Connect + TestFlight ship (Opus, after the [HUMAN] gate)

- [ ] **[HUMAN] gate (founder, ~5 min — can run any time, ideally before Session 1):**
  1. appstoreconnect.apple.com → My Apps → Hangs
  2. App Information (left sidebar, General section)
  3. Name field → `Trubbo` → Save
  4. ASC validates App Store name uniqueness on save. If rejected (name taken), stop and pick a fallback with the agent before any code session runs.
- [ ] Agent: confirm no fastlane/CI file hardcodes the display name (inventory says none — re-verify), then trigger `/testflight` release build
- [ ] Verify: build processes in TestFlight; listing + installed app show "Trubbo"; **[HUMAN]** founder confirms on device
- [ ] Update TODO/INDEX rows to done

## Acceptance

- [ ] Home-screen label, onboarding texts, in-app wordmark + hero show Trubbo (sim + TestFlight device)
- [ ] sk localization intact for the 2 renamed strings
- [ ] App Store Connect / TestFlight name = Trubbo
- [ ] Bundle ID, schemes, match profiles, Sentry, StoreKit, Fly all untouched — ios-ci + release pipeline stay green
- [ ] CONTEXT.md documents the rename (authority for future sessions)

## Notes

- ASC name uniqueness is the only availability check performed; trademark/domain clearance for "Trubbo" is a separate founder call (one-time, outside this issue).
- Cross-refs: #50 (ASC listing — metadata drafts there should use Trubbo when it runs) · #56 (String Catalog — Session 1 touches 2 keys) · #86 (Pencil design sync).
