# Issue 125: MCQ screen: oversized layout, question text clipped, options+listening revealed too early

**Triage:** bug · needs-triage
**Status:** Filed 2026-07-28 from the founder's TestFlight field test. Both halves CONFIRMED by direct code read (layout squeeze + missing reveal gate); the redesign half is design-gated, not implementable as filed. **Track A (reveal gate) + the stem-clipping fix + Track C (regression coverage) DONE 2026-07-28. Track B (minimalist redesign) still design-gated — untouched.**
**Created:** 2026-07-28

## Symptom

Founder, TestFlight, 2026-07-28, with a screenshot. On the MCQ question screen a long Slovak question is **cut off mid-sentence** — the stem is clipped rather than legibly scrollable — because the four option cards occupy most of the screen.

Founder's verdict and ask:

> "The MCQ UI is too big. A more minimalist version needs to be designed. 'Listening — say A-D or the answer' is fine, just make sure the options and the 'listening' text only appear after the timer expires, or after 'start' of recording."

So there are two distinct complaints: (1) the stem does not fit / gets clipped, and (2) the options + the listening pill are on screen from the moment the question starts being read aloud, when they should appear only at answer time.

## Root cause

**CONFIRMED — both halves verified against the code.**

**(1) Stem clipping.** `mcqBody` (`apps/ios-app/Hangs/Hangs/Views/QuestionView.swift:309-378`) puts the question stem in a bare `ScrollView(.vertical, showsIndicators: false)` (`:316-331`) with no minimum-height guarantee, inside a `VStack` whose remaining children all carry fixed or floored heights: `MCQOptionPicker` (`:333`) → 4 × `AnswerOption` at `minHeight: 64` (`Views/Components/MCQOptionPicker.swift:65`, enforced at `Views/Components/Hangs/AnswerOption.swift:117`) ≈ 256pt plus inter-row spacing, then `ListeningPill` (`:342`), `audioStrip` (`:347`, `minHeight: 32`), an optional `CmdListenBar` (`:352`) and the 44pt Skip button (`:359`). In SwiftUI's `VStack` sizing, the floored children are served first and the flexible `ScrollView` absorbs the entire deficit — down to near zero on a long stem. `showsIndicators: false` removes the only cue that content continues, which is why it reads as "clipped, not scrolled".

The same failure mode was already diagnosed and fixed for the sibling `voiceBody` in [#54 — voice overflow (54.2)](issue-54-02-voice-overflow.md): `voiceBody` (`QuestionView.swift:382-420`) wraps its `ScrollView` in `GeometryReader { geo in … .frame(minHeight: geo.size.height) }` (`:392-419`) for exactly this reason. `mcqBody` never got the counterpart.

Note the stem itself does *not* truncate: `HangsQuestionPrompt` uses `.fixedSize(horizontal: false, vertical: true)` (`Views/Components/Hangs/HangsQuestionCard.swift:32`), so the text renders at full height inside the scroll content and its `minimumScaleFactor(0.55)` (`:31`) never engages there. The clipping is purely the collapsed viewport.

**(2) Reveal timing.** `MCQOptionPicker` (`QuestionView.swift:333`) and `ListeningPill` (`:342`) are rendered with **no surrounding condition at all** — they appear as soon as `question.isMultipleChoice` is true, i.e. from the start of `.askingQuestion` while TTS is still reading the stem. The gating pattern already exists two lines away: `audioStrip()` is gated on `quizState == .askingQuestion || .recording` (`:196`) and `CmdListenBar` on `if let hint = viewModel.commandListenerHint` (`:352`). It was simply never applied to these two.

**Zero regression coverage.** `--ui-test-mcq` seeds `previewStartQuizMCQ` whose stem is "What is the largest planet?" (`Models/QuizResponse.swift:224-234`), and `--ui-test-long` seeds `previewStartQuizLong` → `Question.previewLong`, a non-MCQ question (`:184-222`). The two flags are separate `if` blocks in `Utilities/UITestSupport.swift:74-83` where the later one overwrites the earlier, so a long-stem MCQ fixture cannot even be produced today.

## Scope of a fix

**Track A — reveal timing (code-only, no design gate). — DONE 2026-07-28.**
- Gate `MCQOptionPicker` and `ListeningPill` on a post-reveal condition tied to thinking/answer-timer expiry or `.recording`, mirroring the `audioStrip`/`CmdListenBar` conditional pattern already in `QuestionView.swift`.
- Decide and encode what the pre-reveal screen shows instead (see founder decisions), including whether the freed vertical space is given to the stem.
- Voice answers must stay accepted throughout — the gate is visual only; confirm the MCQ voice-match path (`viewModel.mcqVoiceMatchedKey`) is unaffected when the picker is not on screen.
- Shipped as `mcqAnswersRevealed` in `QuestionView.swift` (latch + `mcqRevealDue`). The stem clipping fix (the 54.2 `GeometryReader` + `minHeight` pattern) landed in the same pass on `mcqBody`'s scroll region.

**Residual after Track A (feeds Track B).** Simulator check 2026-07-28 with `--ui-test-mcq --ui-test-long`: pre-reveal the ~300-char stem renders in full and the options/pill are absent, as designed. Post-reveal the option cards take that space back and the stem is cut mid-line. It *does* scroll — asserted in `RS-mcq-long` by swiping and comparing `question.text`'s frame — so nothing is unreachable, but with `showsIndicators: false` there is no cue that it continues, which is precisely the "reads as clipped, not scrolled" complaint. Deliberately NOT changed here: "how much vertical space is reserved for the stem, and what happens beyond it (scroll with a visible affordance, shrink-to-fit, both)" is a Track B design question, not a bug fix.

**Track B — minimalist MCQ layout (DESIGN-GATED).**
- **Gate: a proper design pass with founder sign-off BEFORE any implementation.** Founder asked explicitly for "a more minimalist version to be designed".
- **Process — founder decision 2026-07-28, applies to every UI issue: HTML variants first, Pencil second, code third.** The agent generates several *HTML* variants of the minimalist MCQ layout, the founder reviews and picks one; only the chosen variant is drawn into `design/quiz-agent.pen`, and only then implemented. Never Pencil-first, never code-first. `⌘S` is the founder's step.
- Questions the design session must answer:
  - What is the visual hierarchy at each phase — reading (stem dominant), answering (options dominant), and the transition between them?
  - How much vertical space is reserved for the stem as a floor, and what happens beyond it (scroll with a visible affordance, shrink-to-fit, both)?
  - Does the option row keep the full-width 64/80pt card, or move to a more compact form — and how is the driving-safe touch target preserved if it shrinks?
  - Does the listening pill stay a separate element or fold into the option block / audio strip?
  - Which chrome survives the minimalist pass at all (meta row, replay speaker glyph, timer chips, Skip)?
  - What is the worst-case device the layout must hold on (see open question below)?
- Implementation follows the approved frame, and must guarantee the stem never clips regardless of length — likely the `GeometryReader` + `minHeight` scroll pattern from `voiceBody`/#54.2, a smaller option footprint, or both.

**Track C — regression coverage. — DONE 2026-07-28.**
- Add a long-stem MCQ fixture (a `previewStartQuizMCQLong`, or make `--ui-test-long` compose with `--ui-test-mcq` instead of overwriting it) plus a test asserting the stem is fully reachable and the options/pill are absent pre-reveal.
- Shipped: `Question.previewMCQLong` / `QuizResponse.previewStartQuizMCQLong`, seeded when `--ui-test-mcq` and `--ui-test-long` are passed **together** (the two flags now compose in `UITestSupport` instead of the later one overwriting the earlier), with a 5s answer countdown so the pre-reveal window is observable. Covered by the `QuestionView — MCQ answer reveal gate (#125)` ViewInspector suite and the `RS-mcq-long` XCUITest scenario.

## Founder decisions

Decided 2026-07-28 and implemented (Track A):

- **Pre-reveal screen:** question stem + existing chrome (meta row, timer strip, Skip). The space freed by the hidden option block goes to the stem.
- **Reveal is all-at-once**, no stagger — motion is a liability in a driving context.
- **Skip stays always visible** — the founder's report named only the options and the listening pill, and a driver must be able to bail out of a question they can't answer.
- **"Reveal" = whichever comes first of: the running think/answer countdown hits 0, or `quizState` leaves `.askingQuestion` (recording started).** In the state machine those are the same moment on the happy path — every countdown expiry calls `startRecording()` — so both are wired and the result is latched per question. Latching matters because `startRecording()` can bail back to `.askingQuestion` (backgrounded, shared audio engine busy, capture failure) with no timer left running; without the latch the options would vanish again and the question would be unanswerable. Same reason for the fail-open case: with auto-record OFF *and* `answerTimeLimit == 0` no countdown ever arms, so the cards render from the start.
- **Option card size (64/80pt) is untouched** — that is Track B's call, still design-gated.

## Related

- [#54 — voice overflow (54.2)](issue-54-02-voice-overflow.md) — identical `ScrollView`-squeeze bug, fixed for `voiceBody` only; this is the MCQ-side counterpart that was never done. Its note that "MCQ already avoids this" was based solely on the short test fixture.
- [#45 — iOS MCQ voice + design-port redesign](issue-45-ios-mcq-voice-and-redesign.md) — origin of `MCQOptionPicker` / `AnswerOption` / `ListeningPill`; its open tail items are unrelated.
- [#108 — driving UX papercuts](issue-108-driving-ux-papercuts.md) — the design-first process precedent for item B; no functional overlap.
- [#11 — improve question screen layout](issue-11-question-screen-layout.md) — closed; the same clipping symptom on the pre-redesign UI. Precedent that this failure class recurs across redesigns, not a live duplicate.

**Explicitly OUT of scope:** [#107 — Slovak quiz serves untranslated English question](issue-107-slovak-english-question-leak.md). The same screenshot shows a Slovak stem with English options; that is a separate root cause in the content pipeline and must not be conflated with the layout work here.

## Open questions

- Should a minimum target device (e.g. iPhone SE-class, ~667pt) be an explicit design constraint for Track B? The squeeze is worst there.
- Should Track B assume options are already translated (post-#107) or be designed independent of that bug?
- Is there a max-stem-length budget the generation/translation pipeline should also respect, or is this purely a client-layout fix?
