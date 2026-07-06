# UI proposals 2026-07 — founder decisions (2026-07-05)

Binding record of founder decisions on the 12 planned-UI mockups in
`docs/artifacts/planned-ui-proposals-2026-07.html`. Process: **update Pencil first (#86 — Pencil sync of approved UI), then implement** per the source issues below. Nothing is implemented yet.

## Global directives (apply to every item)

- **G1 — One consistent component set.** The mockup sections drifted in style/components between screens; several proposals conflicted (top-right slot was variously mute / timer / close). Implementation and Pencil must use one unified system. **Binding quiz-screen layout:** top bar = close button + settings button; **timer sits at the bottom near the action buttons**, not in the top bar; **question text is scrollable**; question action buttons (record / skip / type) at the bottom, deliberately **not oversized** so long question text stays visible.
- **G2 — Home free-plan counter (new scope → #87).** Home must show remaining free-plan questions. The quota resets on an interval **TBD after research** (1 / 2 / 3 weeks / month) and Home must also show **time remaining until reset**. Design what paid users see in that slot (TBD in #87).
- **G3 — Copy freeze.** No text changes now; if unavoidable, minimal. **English is the primary and dominant language.**
- **G4 — Screen-level view.** Every change must be checked against the whole screen from a higher perspective, not applied as an isolated patch; never introduce an element onto a screen it doesn't belong to (see item 7's correct-answer example) and never regress a part that already works well.

## Per-item decisions

**1. Settings navigation (#80 — Settings navigation HIG): APPROVED as recommended.**
Variant B (large-title collapse), keep the brand HangsNavChip moved to the leading edge with a "Back" accessibility label, audit sister pushed screens inside #80, pinned-bar title in mono micro-caps.

**2. End-Quiz dialog + countdown fairness (#81 — quiz dialogs & timing fairness): APPROVED with two changes.**
As recommended, **except**: (a) **no countdown pause while typing** an answer — pausing would grant extra thinking time; the countdown keeps running during typed input. (b) Partial scores/stats on early quit: **record everything, display nothing extra** for now — no explicit partial-summary UI, it has no user value yet.

*Amended 2026-07-06 (founder, post-implementation):* (c) **no countdown pause behind dialogs/sheets either** — same abuse rationale as (a); the modal freeze shipped in #81 must be removed. Users can change settings from the Result screen; bad mid-quiz settings are their own problem. (d) **ResultView's X must show the same End-Quiz confirmation alert** as the quiz screen — no immediate quit. Both recorded in `issue-81` for a follow-up pass.

**3. Replay + mute (#85 — replay button + mute control): Variant B, with a smaller replay.**
Mute lives in the bottom audio strip (Variant B) so the top-right slot stays free for the unified top bar (G1 / item 4). Replay button must be **smaller and more minimalistic** than mocked — not a full-size primary button.

**4. Unified quiz top bar (#83 — unify quiz top bar): Variant A + recommendations, overridden by G1 layout.**
Variant A (muted category persistently above the question). All other recommendations accepted. The G1 binding layout wins over anything in the mockup: close + settings on top, timer at the bottom near the action row, scrollable question text, modest action-button sizes.

**5. Drop streak/best-score UI (#84 — drop streak + best-score UI): Variant B (remove the whole Home stats row) — scope explicitly confirmed by founder.**
Caveats: motivational sub-texts are mostly pointless — at most short words/phrases (respect G3 copy freeze). **The current app differentiates correct vs. wrong far better than the mockup did** — keep the existing strong correct/wrong state distinction; the redesign must not weaken it.

**6. Session settings + earcons + image questions (#68 — driving-critical defaults + earcon): APPROVED as recommended, image questions become a Home option.**
Add 10 s to thinkingTime options; Variant A (four menu rows); system sounds 1113/1114 now, unify into the #77 earcon set later; "recording sounds" toggle, default on. **Image questions:** fun, but unsuitable while driving → expose as a **user-selectable option on the Home screen, default OFF**.

**7. UX paper-cuts (#82 — UX paper-cuts bundle): APPROVED with corrections.**
- Correction: the correct answer is shown on the **Result** screen, not the Question screen — the mockup misplaced it. General warning = G4.
- **Skip: no feedback banner/badge.** Skip simply shows the Result screen exactly as today; the user knows they pressed skip.
- Home pickers: OK, but **categories must be multi-select**.
- Call Mode footnote treatment: approved. Haptics: as proposed. Everything else: as recommended.

**8. GPT-style recording orb (TODO idea, no issue): REJECTED entirely.**
No large mic buttons, no orb. Ignore the whole proposal. (TODO idea line marked rejected.)

**9. Quiz-from-prompt (future feature, no issue yet; backend #33/#36 quiz-pack-api): decisions recorded for later.**
Q1: separate screen (not embedded in Home). Q2: **"play immediately" in both parked and driving modes**. Q3–Q5: as recommended. No issue file yet — create at feature kickoff.

**10. Contextual sign-in prompt (#58 — Authentication §9, cross-refs #78/#61): APPROVED as recommended.**

**11. Paywall legal links (from uiux-review, no issue yet): APPROVED with founder inputs.**
Q1: there **will be a website for the app** — Terms/Privacy links point there. Q2: Variant A; "maybe tomorrow" must not look like a button; the whole sheet must be easily dismissible by swipe-down — details deferred to the screen's own implementation pass (do not over-design now). Q3: OK — subscription is wanted eventually but stays deferred post-MVP as recommended. Q4: full sentence.

**12. Typed-vs-voice answer race (#79 — typed answer vs voice race): APPROVED as recommended.**
Added context from founder: on the confirmation screen after a recorded voice answer, **tapping the answer text opens the keyboard for manual editing** of the transcript — the fix must preserve/account for this flow.

## Follow-through

- **#86 — Pencil sync of approved UI** (`issue-86-pencil-sync-approved-ui.md`): update `design/quiz-agent.pen` per all approved items + G1 layout + G2 Home counter, founder reviews frames, then implementation starts in the source issues.
- **#87 — Home free-plan counter + reset countdown** (`issue-87-home-freeplan-counter.md`): research reset interval, design free + paid states. Cross-ref #49 (daily free-limit cost research).
- Implementation of any item starts **only after Pencil review** and stays within the source issue listed above.
