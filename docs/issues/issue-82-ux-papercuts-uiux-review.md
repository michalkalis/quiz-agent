# Issue #82 — UX paper-cuts bundle from the 2026-07-03 UI/UX review

**Triage:** bug · approved 2026-07-05 (with corrections) · ✅ DONE 2026-07-06 (all 6 items shipped, commits `f44976f`..`64af340`; backend deployed to Fly v60)

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

- [x] Each item above fixed (or explicitly founder-declined) in its own commit
- [x] Item 2: per founder correction 2026-07-05 the Result VISUAL stays exactly as today (no skipped banner); only the haptic changed — error buzz → gentle selection tick (review's recommended treatment), locked by intent tests
- [x] Item 3: all listed literals extracted into `Localizable.xcstrings`; ViewInspector tests still pass
- [x] Screenshot-verify run for items 4 and 6 (Home pickers + light-mode ANSWER chip on sim: PASS); item 2 has no visual delta by design (haptic only — not sim-verifiable)

## Implementation notes (2026-07-06)

- **Item 1** = review's Variant B (decision 7 "treatment: approved"): Call Mode toggle re-exposed in the Settings voice group (`settings-call-mode-toggle`), wiring the previously dead `AudioMode`/`toggleAudioMode()`; the mic-picker footnote is now true.
- **Item 4** shipped end-to-end and fixed a latent no-op: the retriever filters on `session.preferred_categories`, which nothing ever populated — the old single-select picker never influenced served questions. `QuizSettings.category: String?` → `categories: [String]` (legacy-blob migration), Home menus show checkmarks, multi-select toggles membership, "All Categories" clears; create-session accepts `categories` (legacy `category` still accepted, now also filters). Backend deployed to Fly (additive OpenAPI change, no migration).
- **Item 5**: replay presents as `fullScreenCover` over the navigation stack instead of swapping the view tree — finishing the replay lands back in Settings.
- **Item 6** measured (WCAG relative luminance): ANSWER pill 2.68:1 / THINK pill 2.96:1 in light mode → FAIL; new per-mode `pinkText` #C2185B (4.73:1) / `blueText` #0A5DC2 (5.07:1) tokens darken only the chip text, capsule tint keeps brand accents, dark mode unchanged. "Type answer instead" chip measured 4.83:1 → passes, untouched.
- Verification: full HangsTests suite green ×2 + backend 299 green (4 new wiring tests); 5 `.stableDump` baselines re-recorded (verified model-only diff). NB: a mid-run RS-correct/RS-incorrect failure was environmental (sim left in landscape by manual driving) — reproduced on clean HEAD, gone after sim reboot; not a code regression.

## Founder decisions 2026-07-05 (pre-implementation UI approval)

Binding record: `docs/design/ui-proposals-2026-07-decisions.md` (decision 7 + globals G1–G4). Pencil frames update first via #86 — Pencil sync of approved UI; implement only after frame review.
- APPROVED with corrections: correct answer belongs on the RESULT screen, not Question (mockup misplaced it — G4 warning). Skip: NO feedback element, Result screen shows as today. Home pickers OK but categories MULTI-SELECT. Call Mode footnote approved; haptics as proposed.
