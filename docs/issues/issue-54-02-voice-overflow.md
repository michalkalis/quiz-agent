# Plan 54.2 — Voice question text overflow pushes Record/Skip off-screen

**Parent:** `issue-54-design-refresh-regressions.md` (§54.2) · **Priority:** P0 (founder #2) · **Status:** ✅ FIXED 2026-06-12 (Pencil-sync + snapshot re-record owed → cross-cutting plan)
**Confidence:** high · **Type:** view-layer layout + behavioural test

_2026-07-06: resolved via issue-54-pencil-snapshot-sync.md sessions 2026-06-12/13._

## Problem (one line)
On the **voice** question screen a long question grows unbounded and shoves the Record/Skip
action row below the screen. The MCQ body already avoids this (its prompt is in a `ScrollView`);
only the voice body regressed in #52.

## Root cause (verified against code)
`QuestionView.voiceBody` (`apps/ios-app/Hangs/Hangs/Views/QuestionView.swift:257`) is a plain
`VStack` with `Spacer()`s and **no `ScrollView`**. The question renders in `.hangsDisplaySM`
(Anton 40pt) with `.minimumScaleFactor(0.55)` **and** `.fixedSize(horizontal:false, vertical:true)`
(`:271–279`). `fixedSize(vertical:true)` forces the text to take whatever height it needs, so a
long question expands the VStack and pushes `voiceActionRow` (`:313`) off-screen.

## Fix approach
Pin `voiceActionRow` at the bottom and make the content above it scroll when it overflows, while
still looking centred when the question is short. Standard pattern:

```
voiceBody = VStack(spacing: 0) {
    GeometryReader { geo in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) { category; question; subtitle
                Spacer(minLength: 24); voiceCenterBlock; Spacer(minLength: 24)
                if isRecording && isStreamingSTT { transcriptCard }; hint
            }
            .frame(minHeight: geo.size.height, alignment: .top)   // centre when short, scroll when tall
        }
    }
    voiceActionRow.padding(.horizontal, 24).padding(.bottom, 28)
    #if DEBUG state probe #endif
}
```
Keep all existing accessibility identifiers (`question.category`, `question.text`,
`question.record`/`question.stop`, `question.skip`, `question.state`). The MCQ body is already
correct — don't touch it.

## Verification (this is the point of the task — don't skip the long-question case)
1. **Add a long-question seed:** in `Hangs/Utilities/UITestSupport.swift` add a `--ui-test-long`
   flag that seeds a *voice* (non-MCQ) question with a very long string (≥ ~180 chars). Mirror the
   existing `--ui-test-mcq` wiring (`UITestSupport.swift:66`, response in `QuizResponse.swift:182`).
2. **Behavioural test** (fails on the bug, passes after the fix): a `RegressionTests`-style test
   that launches with `--ui-test --ui-test-long`, navigates to the question, and asserts
   `question.record.isHittable == true` (XCUITest `isHittable` is false when off-screen). This is
   the genuine regression guard — structural/inspector tests can't prove on-screen visibility.
3. **Screenshot-verify** (CLAUDE.md rule #2 / `docs/testing/screenshot-verify-procedure.md`):
   short question (centred, no scroll) **and** long question (scrolls, Record/Skip visible) — both
   appearances if 54.1 has landed.

## Pencil 1:1 sync (founder requirement)
Reflect the voice-question layout (scroll region + pinned action row) in `design/quiz-agent.pen`
frames `f9csl` (Listen/ready) and `uGhZg` (Capture/recording). Batch with the cross-cutting Pencil
pass (`issue-54-pencil-snapshot-sync.md`) if doing several at once.

## Done criteria
- [x] Long-question UITest is green and was confirmed RED before the fix. (2026-06-12:
      `testRSLongQuestion` failed on unfixed code with "question.record button is not
      hittable", passed after the fix; RS-start + both QuestionView inspector suites green.)
- [x] Record/Skip visible for short and long questions (screenshot-verified in-sim:
      long question scrolls with pinned action row; short question stays centred). VISUAL: PASS.
- [ ] Re-record the QuestionView snapshots (asking/recording) — see pencil/snapshot plan.
- [ ] Pencil voice frames updated (owed — batch with `issue-54-pencil-snapshot-sync.md`).

<!-- obsidian-links:start -->
## Súvisiace issues
[[issue-52-design-refresh-sweep|#52 iOS design-refresh sweep]]
<!-- obsidian-links:end -->
