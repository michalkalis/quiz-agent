# Issue 138: Custom-pack purchase flow redesign — modal flow, post-purchase states, form UX

**Triage:** enhancement · DONE 2026-08-04 (design round + implementation + review round; merged with #140 StoreKit path)
**Reversibility:** a
**Status:** Founder field report 2026-08-04 (first real e2e of the #95 flow). Design round first — verify against iOS HIG (sheets, progress, payment disclosures).
**Created:** 2026-08-04

Founder feedback points 1, 2, 3 (ETA/notify), 8 from the 2026-08-04 test. One coherent redesign of the whole order flow; mechanical MyPacks fixes split to #137.

## A. Flow structure (founder direction)

Today: Settings → push `OrderPackView` (`NavigationLink(value: .orderPack)`, `SettingsView.swift:804`) → push `OrderProgressView` via `navigationDestination(isPresented: $navModel.orderProgressPresented)` (`OrderPackView.swift:62-64`, `NavigationModel.swift:55`). Bug: navigating back from progress lands on the *form* again.

Wanted:
- Whole create-pack flow as a **modal (sheet)**, not a push. After purchase the form must be unreachable (state machine: form → paying → preparing; no back-to-form).
- Post-purchase "pack is being prepared" state with an **approximate duration**; dismissible via X/Close **and** the pink primary button.
- **No-cancellation notice** at the payment step (premium paid service; purchase/generation can't be cancelled once started).
- Settings entry row loses the chevron once modal (`HangsConfigRow(showsChevron:)`, `SettingsView.swift:804`); revisit the row style.

## B. Form UX (founder direction)

`OrderPackView.swift` + `OrderPackViewModel.swift`:
- **ZADANIE** wording is vague — should read as "quiz topic/subject" with a helpful placeholder; make it self-explanatory.
- **Drop the 10-char minimum** (`OrderPackViewModel.swift:28,78-81,94`) — even "a" is allowed; keep the 1000 max.
- **JAZYK**: options are a hardcoded en/sk/cs triple (`OrderPackView.swift:27-31`) disconnected from the global quiz language (`QuizSettings.swift:36`; #130 two-list model). Founder options to resolve in the design round: auto-detect language from the prompt, and/or full quiz-language list preselected from the Home/Settings quiz language.
- **VOLITEĽNÉ Kategória/Motív**: meaning unclear even to the founder — remove, or replace with something self-explanatory (design-round decision; check what the backend actually does with them before deciding).

## C. Readiness communication

How the user learns the pack is ready: at minimum a correct in-app state (#137 does the list mechanics); design round decides ETA copy, notification (push/local?), and the failed-state affordance (backend retry exists: `POST /v1/orders/{id}/retry`).

## Design round — founder decisions (2026-08-04, in-chat)

- **Form = variant A (minimal):** topic + language only; Category/Theme fields removed from the form (backend keeps the optional API fields; client sends nil). Topic placeholder must carry rich examples incl. difficulty/audience ("space for kids, tough questions on Slovak history, 90s music…").
- **Language:** full 10-language quiz list (`Language.supportedLanguages`), preselected from the global quiz language; no auto-detect. Backend whitelist extended en/sk/cs → all 10.
- **Readiness:** in-app only (ETA copy "a few minutes" + My packs pointer; #137 does the live list). No push/local notifications now.
- **Min length:** dropped to 1 on BOTH sides — backend `_validate_guards` also enforced 10, so client-only removal would purchase-then-422. Max 1000 kept.
- Backend research: category/theme genuinely steer sourcing + generation prompts (not decorative); language is serving metadata only (generation is English-only); no numeric ETA exists server-side → static hedged copy.
- Pencil: 5 sheet states added as `NEW_Screen/Pack-Order — 138 Form/Payment/Preparing/Ready/Failed`.

## Acceptance

- [x] Order flow presented as a sheet; after purchase, reopening/dismissing never shows the form for that order (state-machine unit test); back chevron exists only pre-payment (summary → form).
- [x] Preparing state shows ETA copy + Close/X + primary dismiss; dismiss ≠ cancel (polling survives, reopening shows live state).
- [x] Payment step carries the no-cancellation notice (SK+EN).
- [x] Min-length validation gone client AND server (1-char prompt valid end-to-end); 1000 max kept.
- [x] Language menu = full quiz-language list, preselected from global quiz language; backend accepts all 10 codes.
- [x] Failed state offers Try again (backend retry endpoint when order exists) + Close.
- [x] Settings entry row loses the chevron; dead push navigation (orderProgressPresented, AppRoute.orderPack) removed.
