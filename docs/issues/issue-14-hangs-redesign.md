# Issue #14: Hangs Redesign (Pencil → iOS)

## Status: PLANNED

## Source of truth
- Pencil file: `untitled.pen`
- Relevant frames: 8 Redesign screens (top-level nodes with `Redesign/` prefix) + `AppIcon/1024` frame (id `VKGLx`)
- Irrelevant: old `Screen/*` frames, `Home-Dark`, and +14 other top-level frames — will not touch

## Decisions (confirmed with user 2026-04-18)
- **Full rename** Hangs → Hangs (Display name, scheme, target, folders). Bundle ID already `com.missinghue.hangs` per issue tracking in memory.
- **Icon upload path:** Fastlane `deliver` (subagent, Sonnet)
- **Theme mode:** Dark-only for redesign screens (`preferredColorScheme(.dark)` at root). Light mode remnants kept for unchanged screens.
- **Fonts:** SF Pro Display Heavy + SF Mono (no custom font bundling). Close enough to Pencil's Plus Jakarta Sans + Inter.
- **Out of scope:** Onboarding, Paywall, ImageQuestion, LanguagePicker, AudioDevicePicker — not in redesign, leave as-is.

## Visual tokens (from actual redesign screens, not the Pencil variables — designer didn't follow own tokens)
- Background: `#1A1A1A`
- Divider: `#333333`
- Accent (pink block, primary CTA): `#FF4FB6`
- Info accent (blue borders/outlines, secondary CTA): `#0A84FF`
- Success: `#10B981`
- Error: `#FF4444`
- Text primary on dark: `#FFFFFF`, secondary: `#A1A1AA`

## Phased approach

### Phase 0 — App rename (separate commit)
- Display name in `Shared.xcconfig`: `APP_DISPLAY_NAME = Hangs`
- Xcode scheme rename (`Hangs-Local` → `Hangs-Local`, `Hangs-Prod` → `Hangs-Prod`)
- Target rename `Hangs` → `Hangs`
- Folder rename: skip for now (heavy churn — do in separate session, orthogonal to redesign)
- Update CI workflow scheme references, CLAUDE.md, `.claude/rules/ios.md`
- **Verify:** clean build, TestFlight lane dry-run (does not upload, just compiles)

### Phase 1 — Design tokens (`Utilities/Theme.swift`)
- Add `Theme.Hangs` namespace (sibling to existing tokens, not replacement — old views stay working)
- `Colors.Hangs.*`, `Typography.Hangs.mono` (SF Mono), `Typography.Hangs.display` (SF Pro Display Heavy)
- `Spacing.Hangs.*` matching Pencil `space-sm/md/lg/xl`

### Phase 2 — Building blocks (`Views/Components/Hangs/`)
New files, each <150 lines:
- `TerminalLabel.swift` — `// LABEL` monospace + optional status dot
- `StatusChrome.swift` — top bar (`// SESSION.ACTIVE  • REC-IDLE`) + bottom footer (`REG.MARK.01 · PWR ON · V2.1`)
- `HangsPrimaryButton.swift` — pink block CTA, sharp corners, thick shadow
- `HangsSecondaryButton.swift` — blue outline button
- `MetricTile.swift` — `[ DAY_STREAK ] / 47` with label + big number
- `QuestionCard.swift` — bordered card with `[ QUERY ]` label + display-size question text
- `VerdictBadge.swift` — green `CORRECT` / red `INCORRECT` block with `[ VERDICT ]` label

### Phase 3 — Screens (one commit per screen, build check after each)
Mapping Pencil frame → iOS View:

| Pencil frame | File | Change |
|---|---|---|
| `Redesign/Home` (`KVnyA`) | `Views/HomeView.swift` | Full body rewrite |
| `Redesign/Question-Waiting` (`o2Kxv`) | `Views/QuestionView.swift` (idle state) | Rewrite body + mic button |
| `Redesign/Question-Recording` (`JmcE6`) | `Views/QuestionView.swift` (recording state) + `Views/LiveTranscriptView.swift` | Top chrome turns blue during recording |
| `Redesign/Result-Correct` (`N27Qb`) | `Views/ResultView.swift` + `Views/AnswerConfirmationView.swift` | Green verdict block |
| `Redesign/Result-Incorrect` (`oSppI`) | same | Red verdict block |
| `Redesign/Quiz-Complete` (`04gZP`) | `Views/CompletionView.swift` | Big "QUIZ MASTER!" + metric tiles |
| `Redesign/Settings` (`ERDth`) | `Views/SettingsView.swift` | Preserve existing `SettingRow` API, restyle chrome |
| `Redesign/Error` (`h9HgV`) | New: `Views/Components/Hangs/ConnectionLostView.swift` | Currently just alerts — promote to full-screen error state |

Build order: Home → Question (both states) → Result (both) → Completion → Settings → Error.

### Phase 4 — App icon (runs in parallel with Phase 1-2)
1. **Export from Pencil:** `export_nodes` on frame `VKGLx` → save to `apps/ios-app/Hangs/Hangs/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (1024×1024, replaces `887b20b` placeholder)
2. **Commit** separately: `chore(ios): replace placeholder AppIcon with Hangs terminal icon`
3. **Upload to ASC** (subagent, Sonnet):
   - Verify `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, `ASC_API_KEY_CONTENT` present in `apps/ios-app/Hangs/fastlane/.env` or `.env.secret` (gitignored) or shell environment
   - Add a new `upload_icon` lane to `fastlane/Fastfile` using `upload_to_app_store(skip_binary_upload: true, skip_screenshots: true, skip_metadata: false, app_icon: "../Hangs/Assets.xcassets/AppIcon.appiconset/AppIcon.png", force: true)`
   - Run lane; report success/errors back
   - Fallback: if fastlane deliver rejects due to missing metadata, create minimal `fastlane/metadata/` skeleton (primary_category only) and retry

### Phase 5 — Cleanup / deferred
- Light mode for redesign screens — deferred until Pencil has light variants
- Old-design screens (Onboarding, Paywall, ImageQuestion, LanguagePicker) — leave; flag for later
- Custom fonts (Plus Jakarta Sans, Inter) — not needed, SF substitutes match

## Files created
- `docs/issues/issue-14-hangs-redesign.md` (this plan)
- `apps/ios-app/Hangs/Hangs/Views/Components/Hangs/*.swift` (~7 new files)
- `apps/ios-app/Hangs/Hangs/Assets.xcassets/AppIcon.appiconset/AppIcon.png` (overwrite)
- Appended to `apps/ios-app/Hangs/Hangs/Utilities/Theme.swift`
- Appended to `apps/ios-app/Hangs/fastlane/Fastfile` (upload_icon lane)

## Files modified
- `apps/ios-app/Hangs/Hangs/Views/HomeView.swift`
- `apps/ios-app/Hangs/Hangs/Views/QuestionView.swift`
- `apps/ios-app/Hangs/Hangs/Views/LiveTranscriptView.swift`
- `apps/ios-app/Hangs/Hangs/Views/ResultView.swift`
- `apps/ios-app/Hangs/Hangs/Views/AnswerConfirmationView.swift`
- `apps/ios-app/Hangs/Hangs/Views/CompletionView.swift`
- `apps/ios-app/Hangs/Hangs/Views/SettingsView.swift`
- `apps/ios-app/Hangs/Hangs/Config/Shared.xcconfig` (APP_DISPLAY_NAME)
- `.github/workflows/ios-ci.yml`, `.github/workflows/ios-release.yml` (scheme names if renamed)
- `CLAUDE.md`, `.claude/rules/ios.md` (scheme refs)

## Verification
- Manual: run each screen in simulator (iPhone 17 Pro), compare side-by-side with Pencil screenshot
- Automated: `xcodebuild test -scheme Hangs-Local` — existing ViewModel tests unaffected, new View tests not added (SwiftUI snapshot tests not in scope)
- Accessibility: verify WCAG contrast on `#FF4FB6` text-on-black and `#1A1A1A` bg combinations
- App icon: `open apps/ios-app/Hangs/Hangs/Assets.xcassets/AppIcon.appiconset/` (Finder QuickLook) — visual spot-check before ASC upload
- ASC: after lane runs, login to App Store Connect → app "Hangs" → App Information → verify icon appears

## Risk / rollback
- Rename phase can break TestFlight signing if scheme name mismatches Matchfile — separate commit so rollback is `git revert` only that commit
- Redesign commits are per-screen, each builds independently → partial rollback possible
- App icon is a single file swap, trivial rollback

## Open follow-ups (after this issue)
- Folder rename `Hangs/` → `Hangs/` in filesystem — do in dedicated session, big diff
- Light-mode variants for Pencil redesign screens
