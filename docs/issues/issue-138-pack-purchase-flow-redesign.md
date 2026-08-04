# Issue 138: Custom-pack purchase flow redesign — modal flow, post-purchase states, form UX

**Triage:** enhancement · design-gated (HTML variants → founder pick → Pencil → code)
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

## Process

1. HIG review + HTML variants (flow states + form) → founder picks in-chat.
2. Pencil sync (`design/quiz-agent.pen`), founder ⌘S.
3. Implement + tests (state machine unit tests: no route back to form post-purchase; sheet dismiss rules).

## Acceptance (sketch — finalize after design pick)

- [ ] Order flow presented as a sheet; after purchase, reopening/dismissing never shows the form for that order (state-machine unit test).
- [ ] Preparing state shows ETA copy + Close/X + primary dismiss (snapshot/unit).
- [ ] Payment step carries the no-cancellation notice (unit/snapshot; SK+EN).
- [ ] Min-length validation gone (unit test: 1-char prompt valid); 1000 max kept.
- [ ] Language control per founder pick; defaults follow the global quiz language.
- [ ] Settings entry updated (no chevron on a modal trigger).
