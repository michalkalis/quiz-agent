# Issue #82 — UX paper-cuts bundle from the 2026-07-03 UI/UX review

**Triage:** bug · needs-triage (draft from UI/UX review 2026-07-03)

**Created:** 2026-07-03 · **Founder:** Michal · **Source:** UI/UX review 2026-07-03 (each item sim-observed and/or code-verified)

**Severity:** low individually — bundled so they can land as one small sweep.

## Items

1. **Stale "Call Mode" footnote.** Mic-picker sheet says "Switch to Call Mode in settings to use
   Bluetooth microphones." but Settings exposes no such control — the `AudioMode` model and
   `toggleAudioMode()` are still wired yet unreachable (dead: single occurrence = its definition).
   Either remove the footnote or re-expose the toggle — decide, don't leave the dangling pointer.
   Evidence: `AudioDevicePickerView.swift:36`; `Models/AudioMode.swift:11-42`; `QuizViewModel+Audio.swift:174-190`; shot `07-settings-mic-picker.png`.

2. **Skipped question renders as "MISSED IT." (incorrect styling).** Backend correctly returns
   `skipped` (0 points, no streak change; `apps/quiz-agent/app/quiz/flow.py:174-191`), but
   `ResultView`'s banner is binary on `isCorrect`, so a skip gets the punishing incorrect visual +
   error haptic. `Components/ResultBadge.swift:16,83` already supports a `.skipped` case — the
   banner doesn't. Render skips neutrally ("Skipped", no error haptic).
   Evidence: `ResultView.swift:75,80,286-287,359`.

3. **Sign-in block strings bypass the String Catalog** (added after #56's extraction): 
   `SettingsView.swift:90` ("Delete account?" alert), `:183`, `:213`, `:218`, `:223`, `:235`, `:246`.
   Extract per the localization rules in `.claude/rules/ios.md` so future Slovak translation (#56
   tail) covers them.

4. **Home selectors show no current-selection state.** Language/Difficulty/Categories are plain
   SwiftUI Menus without a checkmark on the active choice, and "Categories" is single-select despite
   the plural label. Add selection checkmarks; rename label to "Category" (or make it multi-select —
   founder call, see review report). Evidence: shots `02–04-*.png`.

5. **"Replay intro" returns to Home instead of Settings.** Completing the onboarding replay from
   Settings drops the user at Home. Return to the originating screen.

6. **Light-mode contrast follow-up (verify, may be fine):** the "ANSWER Ns" timer pill and the
   "Type answer instead" chip are borderline low-contrast in light mode — run a contrast check
   against WCAG AA and adjust if failing. Evidence: shot `25-light-quiz-question.png`.

## Acceptance

- [ ] Each item above fixed (or explicitly founder-declined) in its own commit
- [ ] Item 2: skip result shows neutral "skipped" treatment, no error haptic; snapshot updated
- [ ] Item 3: all listed literals extracted into `Localizable.xcstrings`; ViewInspector tests still pass
- [ ] Screenshot-verify run for items 2, 4, 6
