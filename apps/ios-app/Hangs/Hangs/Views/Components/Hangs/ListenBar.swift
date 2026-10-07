//
//  ListenBar.swift
//  Hangs
//
//  Issue #125 Track B + the "one ListenBar, text swaps" addendum
//  (docs/design/ui-variants-2026-07-28-decisions.md). One shared full-width
//  listening bar, docked as the first footer row below GlowSweepLine, whose
//  text/accent swaps by mode — the app only ever listens for EITHER commands OR
//  an answer, never both (founder, 2026-07-28):
//
//   - `.command`  — teal, "LISTENING FOR COMMANDS" in the COMMAND language (#120),
//                    shown while a command window is armed.
//   - `.answer`   — pink, "LISTENING — SAY A–D / TRUE OR FALSE / YOUR ANSWER",
//                    app-locale localized, shown while answering.
//
//  Match/no-match feedback follows #122 Variant C (teal sweep / amber breath) in
//  both modes and re-tints the bar (lit / lit-miss).
//
//  #131 Track F, Option B "full + slim" (founder pick 2026-07-29): this is now
//  the ONLY listening bar in the app — `CmdListenBar` is retired, Home /
//  Confirmation / Result all render this one. A `size` parameter is the single
//  fork allowed: `.full` (~56pt, caption over the words) on quiz screens, `.slim`
//  (~40pt, short caption + words on ONE row) on Home, where the command never
//  changes and the screen has content to show.
//
//  #131 Track C (founder, 2026-07-29):
//   - NO mute button. It was a duplicate of the question audio strip's (#85), and
//     the strip is the one place a driver learns to reach for. The strip is now
//     rendered in every state this bar shows in.
//   - Command mode carries a SUB-LINE with the actual words to say, sourced from
//     `VoiceCommandLexicon.hint(on:language:)` via the caller — "LISTENING FOR
//     COMMANDS" alone never told anyone what a command is.
//   - The amber no-match state swaps that sub-line for a corrective hint. Colour
//     alone is not feedback: a driver glancing at an amber bar must read what to
//     do differently, not infer it.
//
//  #132 Track B, variant A "odpočet v lište" (founder pick 2026-07-29): the MCQ
//  think-phase countdown lives IN this bar — command mode gains an optional
//  `thinkCountdown`: a teal fill anchored left drains leftwards as the window
//  empties and the caption counts the seconds down. At zero the call site swaps
//  the mode to `.answer`, so one element carries both states (nothing appears or
//  disappears). The command-word sub-line stays exactly as every other command
//  bar renders it — the founder's correction to the mock, which had dropped it.
//
//  #179 D1, variant A (founder pick 2026-09-15): on the QUESTION screen this bar
//  has FOUR states and they are the same for MCQ and open questions — reading the
//  question → think + countdown → listening for the answer → evaluating. The
//  state model itself lives in `QuestionListenPhase`; this view only renders what
//  it is handed. Two of the four are new modes here (`.readingQuestion`,
//  `.evaluating`) because the bar previously had nothing to say while the TTS was
//  reading and simply VANISHED while an answer was graded — which the founder
//  read as a frozen screen (TF build 61). The command words become CHIPS
//  (`commandWords`) instead of one sentence: a chip row is read from a car mount
//  faster than a sentence, and it leaves room for a fourth word. The other
//  screens (Home / result / confirmation) keep the `commandHint` sentence — D1
//  was a decision about the question screen only.
//
//  #185 track F, variant F2 "Lišta dýcha" (founder pick 2026-09-25): while the
//  driver answers, the bar has to answer "does the mic hear me?" from the corner
//  of the eye. In the answer and in-flight states it grows to 58pt and says its
//  state in large text — "Listening…" → "Capturing…" (speech heard) →
//  "Processing…" — with the instruction as a small caption under it, and the
//  whole capsule glows with the live mic level (`inputLevel`). Command states
//  and the slim size keep the layout above.
//
//  #189 (founder feedback 2026-09-29): the confirmation sheet tore the listener
//  down for the answer read-back and the pill simply vanished for the ~4 s it
//  took to come back — read as a frozen sheet. `.readingAnswerBack` fills that
//  gap: same teal/layout as `.command` (same words below), but a speaker glyph
//  and no "live mic" dots, since nothing is heard yet.
//
//  #188 G11 (founder audit D13 + M8): on the QUESTION screen every state now
//  speaks in the F2 status layout. "Reading the question" and the think state
//  were a tiny teal mono caption while only "Listening…" read at a glance; and
//  the countdown showed twice (here and in the Start button). Now the state is
//  the large line in every state, the capsule colour says which state it is
//  (teal reading/think, pink listening, grey in flight), and the seconds left —
//  think window or recording window — are a large number at the trailing edge,
//  the ONE place the quiz counts down. The slim bar and the other screens'
//  command bars (Home, confirmation, result) are unchanged.
//

import SwiftUI

/// #173 B1: which question's listening bar the driver has hidden with the ✕.
/// A value rather than a bare flag, so "only for the current question" is a
/// property of the type instead of a convention at the call site — and so the
/// rule is assertable without driving SwiftUI `@State` through a hosted view.
struct ListenBarDismissal: Equatable {
    private var dismissedQuestionId: String?

    init() {}

    mutating func dismiss(questionId: String) { dismissedQuestionId = questionId }

    /// Nothing carries across questions: a dismissal that outlived its question
    /// would quietly remove the only surface naming the voice commands for the
    /// rest of the quiz.
    func isHidden(questionId: String) -> Bool { dismissedQuestionId == questionId }
}

struct ListenBar: View {
    private enum Metrics {
        /// #188 G11: the countdown beside the 17pt status line — one step
        /// larger, so the number is what the eye lands on.
        static let statusSeconds: CGFloat = 20
    }

    /// The answer form the driver should speak — drives the answer-mode caption.
    enum AnswerKind: Equatable {
        case mcq // multiple choice labelled 1–4 (#185 track G)
        case mcqLetters // multiple choice labelled A–D (the options are numbers)
        case trueFalse // 2-option true/false
        case open // free-text spoken answer (recording)
    }

    /// What the bar is saying. The app only ever listens for EITHER commands OR
    /// an answer, never both (founder, 2026-07-28) — and since #179 D1 it also
    /// speaks in the two states where it is listening for nothing at all, rather
    /// than leaving the slot empty.
    enum Mode {
        case command // listening for hands-free commands (teal)
        case readingQuestion // #179 D1 state 1: the TTS is reading; commands armed (teal)
        /// #189: the confirmation/no-answer sheet's own state while the answer
        /// read-back plays or the listener has not yet reported live afterwards
        /// (teal, like `.command` — the words below are the same).
        case readingAnswerBack
        case answer(AnswerKind) // listening for an answer (pink)
        case evaluating // #179 D1 state 4: the answer is being graded; nothing is heard (grey)
        case skipping // #181: the question is being skipped; nothing is heard (grey)
    }

    /// The two "in flight" modes: nothing is listening, the bar only proves the
    /// app is alive. They differ only in what they SAY.
    private var isBusy: Bool {
        switch mode {
        case .evaluating, .skipping: return true
        case .command, .readingQuestion, .readingAnswerBack, .answer: return false
        }
    }

    /// #131 Track F Option B — the one permitted variation. Same colours, same
    /// states, same component; only the height and the row layout differ.
    enum Size {
        case full // quiz screens: caption row over the words to say
        case slim // Home: short caption + the words on a single ~40pt row
    }

    /// #132 Track B — the think-phase window this bar is counting down. The fill
    /// fraction is `remaining/total`; a zero total hides the fill (no window is
    /// draining, e.g. while the question is still being read).
    struct ThinkCountdown: Equatable {
        let remaining: Int
        let total: Int
    }

    let mode: Mode

    /// #122 Variant C transient tint — overrides the mode accent while live.
    var feedback: VoiceFeedbackPhase = .idle

    /// #122 follow-up (TF 2026-10-07): the recognized-but-not-yet-fired command
    /// as a ready caption (`VoiceCommandLexicon.recognizingCaption`, command
    /// language, verbatim). Shown with a spinner while `feedback == .recognizing`.
    var recognizingWord: String? = nil

    /// The screen's concrete command words, already rendered by
    /// `VoiceCommandLexicon.hint(on:language:)` (the same string the caller gates
    /// the bar on). Command mode only; nil keeps the bar single-line.
    var commandHint: String? = nil

    /// #179 D1: the command words as discrete chips under the caption — the
    /// question screen's form of the same promise `commandHint` makes as a
    /// sentence elsewhere. Rendered in the COMMAND language (#120) like the
    /// sentence, and empty when the words are hidden (Settings) or the listener
    /// is not armed, so a chip never offers a word that would not be heard.
    var commandWords: [String] = []

    /// Full on quiz screens, slim on Home (#131 Track F).
    var size: Size = .full

    /// #185 (founder, variant D1): the answer sheet listens for an ANSWER as
    /// well as commands, so its caption is the short "LISTENING" alone.
    var shortCaption: Bool = false

    /// Command-mode caption language (#120) — independent of the app/quiz locale.
    var language: CommandLanguage = .english

    /// #132 Track B: MCQ think-phase countdown. Command mode only — answer mode
    /// ignores it (the mic is already live, there is nothing left to count down).
    var thinkCountdown: ThinkCountdown? = nil

    /// #185 track F: the answer recording has heard speech — "Capturing…"
    /// instead of "Listening…". Answer mode only.
    var speechHeard: Bool = false

    /// #185 track F: the live mic level the capsule glows with. Answer mode
    /// only; nil (previews, tests) glows at the quiet level.
    var inputLevel: RecordingInputLevel? = nil

    /// #188 G11: seconds left in the answer-recording window. Answer mode only;
    /// nil or 0 = no window running, nothing shown. It moved here from the
    /// Stop button so the quiz counts down in one place.
    var answerRemaining: Int? = nil

    /// #173 B1 (founder locked 2026-09-07): a trailing ✕ that hides the bar for
    /// the CURRENT question only. Nil = no dismiss affordance (Home, result,
    /// confirmation — screens where the bar is the only thing talking). The
    /// dismissal is deliberately not remembered: the next question needs its own
    /// decision, and a permanently hidden command bar is how a driver loses the
    /// hands-free commands without noticing.
    var onDismiss: (() -> Void)? = nil

    /// The countdown, iff the mode can host one.
    private var activeThinkCountdown: ThinkCountdown? {
        guard case .command = mode else { return nil }
        return thinkCountdown
    }

    /// True while the bar is listening for COMMANDS — the two states that may
    /// name words (D1 states 1 and 2, plus Home / result / confirmation).
    private var isCommandMode: Bool {
        switch mode {
        case .command, .readingQuestion, .readingAnswerBack: return true
        case .answer, .evaluating, .skipping: return false
        }
    }

    /// The chips actually rendered. Answer mode has none by the 2026-07-28 rule
    /// (a command spoken there is not heard, so offering one would be a lie);
    /// evaluating has none because nothing is listening at all.
    private var chipWords: [String] { isCommandMode ? commandWords : [] }

    /// #189: the trailing "live mic" dots only mean something while a command
    /// window is actually armed — the read-back/settle state never had a live
    /// mic to represent.
    private var showsDots: Bool {
        switch mode {
        case .command, .readingQuestion: return true
        case .readingAnswerBack, .answer, .evaluating, .skipping: return false
        }
    }

    /// #122 follow-up: command modes only — answer mode and the busy states have
    /// no armed command window, so hearing/recognizing say nothing there.
    private var feedbackIsLive: Bool { isCommandMode && !isBusy }
    private var isHearing: Bool { feedbackIsLive && feedback == .hearing }
    private var isRecognizing: Bool { feedbackIsLive && feedback == .recognizing }

    /// Left-anchored drain fraction, nil when no window is running.
    private var thinkFillFraction: CGFloat? {
        guard let countdown = activeThinkCountdown, countdown.total > 0 else { return nil }
        return min(max(CGFloat(countdown.remaining) / CGFloat(countdown.total), 0), 1)
    }

    // MARK: - Tint tokens

    private var teal: Color { Theme.Hangs.Colors.accentTeal }
    private var amber: Color { Theme.Hangs.Colors.warning }
    private var pink: Color { Theme.Hangs.Colors.pink }

    /// The bar's resting accent before any feedback tint applies.
    private var modeAccent: Color {
        switch mode {
        case .command, .readingQuestion, .readingAnswerBack: return teal
        case .answer: return pink
        case .evaluating, .skipping: return Theme.Hangs.Colors.muted
        }
    }

    /// Waveform + caption colour: feedback wins over the mode accent (#122).
    private var accent: Color {
        // Nothing is heard while an answer is graded, so a match/no-match tint
        // there would be a claim about a mic that is closed.
        if isBusy { return modeAccent }
        switch feedback {
        case .idle: return modeAccent
        case .matched: return teal
        case .unmatched: return amber
        case .hearing, .recognizing: return modeAccent
        }
    }

    /// Background fill — matched/unmatched are the #122 lit /
    /// lit-miss tints; idle uses the mode's soft accent.
    private var fill: Color {
        if isBusy { return Theme.Hangs.Colors.muted.opacity(0.10) }
        switch feedback {
        case .matched: return teal.opacity(0.22)
        case .unmatched: return amber.opacity(0.12)
        case .hearing, .recognizing where feedbackIsLive: return teal.opacity(0.14)
        case .idle, .hearing, .recognizing:
            switch mode {
            case .command, .readingQuestion, .readingAnswerBack: return teal.opacity(0.08)
            // #185 track F: a shade warmer once speech is heard (F2 "hot").
            case .answer: return speechHeard ? pink.opacity(0.18) : Theme.Hangs.Colors.pinkSoft
            case .evaluating, .skipping: return Theme.Hangs.Colors.muted.opacity(0.10)
            }
        }
    }

    private var border: Color {
        if isBusy { return Theme.Hangs.Colors.muted.opacity(0.35) }
        switch feedback {
        case .matched: return teal.opacity(0.75)
        case .unmatched: return amber.opacity(0.55)
        case .hearing, .recognizing where feedbackIsLive: return teal.opacity(0.5)
        case .idle, .hearing, .recognizing:
            switch mode {
            case .command, .readingQuestion, .readingAnswerBack: return teal.opacity(0.35)
            case .answer: return pink
            case .evaluating, .skipping: return Theme.Hangs.Colors.muted.opacity(0.35)
            }
        }
    }

    private var barHeight: CGFloat {
        if usesStatusLayout { return Self.statusHeight }
        return Self.height(size: size, hasSubLine: subLine != nil || !chipWords.isEmpty)
    }

    /// #185 track F (F2): the answer and in-flight states on the full bar say
    /// their state in large text inside a taller bar. The command states keep
    /// the caption-over-chips layout; the slim bar keeps its single row.
    ///
    /// #188 G11: the question screen's reading and think states join them —
    /// both are question-screen-only (the think state is the command mode WITH
    /// a countdown), so the command bars of the other screens keep their layout.
    var usesStatusLayout: Bool {
        guard size == .full else { return false }
        switch mode {
        case .answer, .evaluating, .skipping, .readingQuestion: return true
        case .command: return activeThinkCountdown != nil
        case .readingAnswerBack: return false
        }
    }

    /// #188 G11: the large trailing number — the think window in the status
    /// layout (the small layouts keep it inside the caption), the recording
    /// window while listening. Internal for tests.
    var trailingSeconds: Int? {
        if case .answer = mode {
            guard let answerRemaining, answerRemaining > 0 else { return nil }
            return answerRemaining
        }
        guard usesStatusLayout, let countdown = activeThinkCountdown else { return nil }
        return countdown.remaining
    }

    /// Whether the capsule glows with the mic level — only while the mic is
    /// open for an answer (a glow over a closed mic would be a lie).
    private var showsLevelGlow: Bool {
        if case .answer = mode { return true }
        return false
    }

    /// F2's 58pt: large enough to read at a glance, 10pt over the command
    /// bar — the price the MCQ grid pays only while an answer is in flight.
    static let statusHeight: CGFloat = 58

    /// Pure so the founder-picked sizes are assertable without rendering.
    /// Internal for tests.
    ///
    /// #173 B1: the quiz bar lost 8pt (56 → 48 with the words, 44 → 38 without).
    /// It moved ABOVE the MCQ option grid, where every point it takes is a point
    /// the options do not get, and the founder's note was "menšia výška". Home's
    /// slim bar is unchanged — it was never in anything's way.
    static func height(size: Size, hasSubLine: Bool) -> CGFloat {
        switch size {
        case .slim: return 40
        case .full: return hasSubLine ? 48 : 38
        }
    }

    /// The sub-line under the caption: the words to say, or — on a no-match — a
    /// corrective hint that still names them. In answer mode it is the answer
    /// instruction (#185 track F) — under the large status on the full bar, beside
    /// the status on the slim one, so no size loses it.
    private var subLine: Text? {
        if case .answer = mode { return answerInstruction }
        // #179 D1 state 4: the line that stops "the screen froze" — it says the
        // wait is expected and that speaking will not help.
        if case .evaluating = mode {
            return Text("No need to say anything")
        }
        // #181: no answer exists, so no "evaluating" — say what is happening.
        if case .skipping = mode {
            return Text("Loading the next question")
        }
        // Chips replace the sentence wherever they are given (question screen).
        guard isCommandMode, chipWords.isEmpty, let commandHint else { return nil }
        switch feedback {
        case .unmatched:
            return Text("Didn't catch that. \(commandHint)")
        case .idle, .matched, .hearing, .recognizing:
            return Text(verbatim: commandHint)
        }
    }

    /// Caption as a `Text`: verbatim command caption (command language) OR a
    /// catalog-localized answer prompt. Reused verbatim as the a11y label.
    /// With a think countdown the caption counts the window down instead —
    /// catalog-localized like the answer captions, since it narrates the answer
    /// flow ("listening in N s"), not the command engine.
    private var captionText: Text {
        if let countdown = activeThinkCountdown {
            // #188 G11: in the status layout the seconds are their own large
            // number, so the state line is the one word.
            if usesStatusLayout { return Text("Think") }
            return Text("THINK — LISTENING IN \(countdown.remaining) S")
        }
        // #122 follow-up: a matched command waiting to fire names itself.
        if isRecognizing, let recognizingWord { return Text(verbatim: recognizingWord) }
        switch mode {
        // #179 D1 state 1: during the read the bar was missing entirely on MCQ
        // (founder screenshot 9) — it now names what the app is doing.
        case .readingQuestion:
            return Text("Reading the question")
        // #189: the sheet's own "not live yet" state — read-back or settle.
        case .readingAnswerBack:
            return Text(verbatim: VoiceCommandLexicon.readingBackCaption(language: language))
        // #185 track F: the same word the Stop button says while it spins.
        case .evaluating:
            return Text("Processing…")
        case .skipping:
            return Text("Skipping the question")
        case .command:
            // #174: without the words sub-line (hints outgrown) the miss must
            // still be readable, not just amber — so it takes the caption slot.
            if feedback == .unmatched, commandHint == nil {
                return Text("Didn't catch that")
            }
            return Text(verbatim: VoiceCommandLexicon.listeningCaption(
                language: language,
                short: size == .slim || shortCaption
            ))
        // #185 track F: the state, not the instruction — the instruction
        // moved to `answerInstruction` (the sub-line).
        case .answer:
            return speechHeard ? Text("Capturing…") : Text("Listening…")
        }
    }

    /// #185 track F: the answer-mode sub-line. While waiting for speech it is
    /// the instruction; once speech is heard it says how the recording will
    /// end, so nobody talks on to fill the silence.
    private var answerInstruction: Text? {
        guard case let .answer(kind) = mode else { return nil }
        if speechHeard { return Text("I'll stop when you go quiet") }
        switch kind {
        // #171 Track I: answering with the option TEXT works (and goes through
        // the confirmation sheet like every other answer), so the caption must
        // say so — "say A–D" read as letters-only.
        // #185 track G: the caption names the labels the options carry.
        case .mcq: return Text("Say 1–4 or the answer")
        case .mcqLetters: return Text("Say A–D or the answer")
        case .trueFalse: return Text("Say true or false")
        case .open: return Text("Say your answer")
        }
    }

    var body: some View {
        content
            // Combined so VoiceOver reads one "listening … say X" element.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("listen-bar")
            .padding(.leading, usesStatusLayout ? 18 : (size == .slim ? 16 : 14))
            .padding(.trailing, trailingPadding)
            // The ✕ is a sibling of the combined element, never inside it: VoiceOver
            // must reach the control, not read "hide" as part of the instruction.
            // #188 G11: laid over the trailing padding reserved for it, never over
            // the content — the countdown now ends the row and sat under it.
            .overlay(alignment: .trailing) { dismissButton }
            .frame(maxWidth: .infinity)
            // A floor, not a fixed height: at large text the status line must
            // never be clipped by its own capsule (#188 G9).
            .frame(minHeight: barHeight)
            .background(
                ZStack(alignment: .leading) {
                    Capsule().fill(fill)
                    // #132 B: the draining think window — right edge retreats
                    // leftwards each tick ("vyprázdňuje sa doľava").
                    if let fraction = thinkFillFraction {
                        GeometryReader { geo in
                            Rectangle()
                                .fill(teal.opacity(0.14))
                                .frame(width: geo.size.width * fraction)
                                .animation(.linear(duration: 1), value: fraction)
                        }
                        .clipShape(Capsule())
                    }
                }
            )
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            // #185 track F: the breathing glow sits OUTSIDE the capsule, so it
            // never changes the bar's own colours or its layout slot.
            .background {
                if showsLevelGlow {
                    ListenBarLevelGlow(meter: inputLevel, color: accent)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: feedback)
            .animation(.easeInOut(duration: 0.25), value: speechHeard)
    }

    /// Room for the ✕ when there is one (F2 widens it with the larger bar).
    private var trailingPadding: CGFloat {
        if onDismiss != nil { return usesStatusLayout ? 44 : 40 }
        return usesStatusLayout ? 18 : 14
    }

    @ViewBuilder
    private var content: some View {
        if usesStatusLayout {
            statusContent
        } else {
            standardContent
        }
    }

    /// #185 track F (F2): large state + small caption, glyph at 18pt.
    /// #188 G11: the command words (reading/think) sit under the state as chips,
    /// and the seconds left are a large trailing number.
    private var statusContent: some View {
        HStack(spacing: Theme.Hangs.Spacing.sm) {
            leadingGlyph
            VStack(alignment: .leading, spacing: 2) {
                captionText
                    .font(.hangsBody(17, weight: .bold))
                    .foregroundColor(statusTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !chipWords.isEmpty {
                    words
                } else if let subLine {
                    subLine
                        .font(.hangsMono(10, weight: .medium))
                        .tracking(1)
                        .textCase(.uppercase)
                        .foregroundColor(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        // Same id contract as the standard layout: only command
                        // words answer to "listen-bar.commands".
                        .accessibilityIdentifier(isCommandMode ? "listen-bar.commands" : "listen-bar.note")
                }
            }
            Spacer(minLength: 8)
            if let trailingSeconds {
                // Inter with tabular digits, not the mono face: a mono space is a full
                // character wide, and "27 s" read as two things ("27    s").
                secondsLabel(trailingSeconds, font: .hangsBody(Metrics.statusSeconds, weight: .semibold))
            }
        }
    }

    /// #188 G11 (founder review): the large state line carries the state's
    /// colour where the founder asked for it — reading and think stay green
    /// (teal text, readable in light mode); listening and in-flight keep ink,
    /// as #185 F2 picked, with the capsule saying pink or grey.
    private var statusTextColor: Color {
        switch mode {
        case .readingQuestion, .command, .readingAnswerBack: return Theme.Hangs.Colors.tealText
        case .answer, .evaluating, .skipping: return Theme.Hangs.Colors.ink
        }
    }

    /// The countdown number — tabular so the bar does not jitter each tick, and
    /// never scaled away: it is the one part the driver cannot infer.
    private func secondsLabel(_ seconds: Int, font: Font) -> some View {
        Text(verbatim: "\(seconds) s")
            .font(font)
            .monospacedDigit()
            .foregroundColor(statusTextColor)
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("listen-bar.seconds")
    }

    private var standardContent: some View {
        HStack(spacing: Theme.Hangs.Spacing.xs) {
            leadingGlyph

            switch size {
            case .full:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        caption
                        trailingIndicator
                    }
                    words
                }
            case .slim:
                // One row: the short caption and the words share the 40pt bar.
                caption
                trailingIndicator
                words
            }

            Spacer(minLength: 8)
            // #188 G11: the recording window on the slim bar (the think window
            // is already inside its caption).
            if let trailingSeconds {
                secondsLabel(trailingSeconds, font: .hangsMonoLabel)
            }
        }
    }

    // MARK: - Parts

    /// Clock while a think window drains, spinner while the answer is graded,
    /// live waveform once listening — one glyph slot, four states (#132 B, #179 D1).
    @ViewBuilder
    private var leadingGlyph: some View {
        // #189: a speaker, not the listening waveform — nothing is heard while
        // the answer plays back or the mic is still settling.
        if case .readingAnswerBack = mode {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: usesStatusLayout ? 18 : 14, weight: .semibold))
                .foregroundColor(accent)
                .accessibilityHidden(true)
        } else if isBusy {
            ProgressView()
                .controlSize(usesStatusLayout ? .regular : .small)
                .tint(accent)
                .accessibilityIdentifier("listen-bar.spinner")
        } else {
            Image(systemName: activeThinkCountdown == nil ? "waveform" : "clock")
                .font(.system(size: usesStatusLayout ? 18 : 14, weight: .semibold))
                .foregroundColor(accent)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                              isActive: activeThinkCountdown == nil)
                .accessibilityHidden(true)
        }
    }

    /// The bar as one VoiceOver element: state, seconds left, then what to say.
    private var accessibilityText: Text {
        var text = captionText
        if let trailingSeconds {
            text = text + Text(verbatim: ", ") + Text("\(trailingSeconds) seconds left")
        }
        if let spokenSubLine {
            text = text + Text(verbatim: ". ") + spokenSubLine
        }
        return text
    }

    /// What VoiceOver reads after the caption: the sentence, or the chips joined
    /// into one — a driver using VoiceOver must hear the words too.
    private var spokenSubLine: Text? {
        if let subLine { return subLine }
        guard !chipWords.isEmpty else { return nil }
        return Text(verbatim: chipWords.joined(separator: ", "))
    }

    /// The B1 dismiss ✕ — dim, outside the combined a11y element so VoiceOver
    /// reads the bar and its control separately.
    @ViewBuilder
    private var dismissButton: some View {
        if let onDismiss {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.Hangs.Colors.muted.opacity(0.75))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Sits in the trailing padding this bar reserves for it (40–44pt).
            .padding(.trailing, Theme.Hangs.Spacing.xxs)
            .accessibilityLabel(String(localized: "Hide the listening bar", comment: "Accessibility label for the button that hides the in-quiz listening bar for the current question"))
            .accessibilityIdentifier("listen-bar.dismiss")
        }
    }

    private var caption: some View {
        captionText
            .font(.hangsMono(11, weight: .medium))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundColor(accent)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    /// The words to say. Command mode only — answer mode's caption IS the
    /// instruction. Never wraps: it must stay one glanceable line at 40pt too.
    @ViewBuilder
    private var words: some View {
        if !chipWords.isEmpty {
            HStack(spacing: Theme.Hangs.Spacing.xxs) {
                // #131 Track C: colour alone is not feedback — a miss must say
                // what to do. With chips the words stay put (they are still the
                // answer) and the correction leads the row, so the #132 countdown
                // in the caption above is never blanked by a mis-heard word.
                if feedback == .unmatched {
                    Text("Didn't catch that")
                        .font(.hangsBody(10, weight: .medium))
                        .foregroundColor(accent)
                        .lineLimit(1)
                }
                ForEach(chipWords, id: \.self) { word in
                    Text(verbatim: word)
                        .font(.hangsMono(10, weight: .medium))
                        .foregroundColor(accent)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accent.opacity(0.12)))
                }
            }
            .minimumScaleFactor(0.6)
            .accessibilityIdentifier("listen-bar.commands")
        } else if let subLine {
            subLine
                .font(.hangsBody(11, weight: .medium))
                .foregroundColor(accent.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Only command words answer to "listen-bar.commands" — the
                // evaluating note is a status line, and a test asking "are any
                // words on offer?" must not be answered by it.
                .accessibilityIdentifier(isCommandMode ? "listen-bar.commands" : "listen-bar.note")
        }
    }

    /// The live-mic dots, or — while a matched command waits to fire — a small
    /// teal spinner in their place (#122 follow-up, TF 2026-10-07).
    @ViewBuilder
    private var trailingIndicator: some View {
        if showsDots {
            if isRecognizing, recognizingWord != nil {
                ProgressView()
                    .controlSize(.mini)
                    .tint(teal)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("listen-bar.recognizing")
            } else {
                dots
            }
        }
    }

    /// Three trailing dots fading back (opacity 1 · 0.55 · 0.3) — the "live mic"
    /// tell migrated from `CmdListenBar` when it was retired (#131 Track F).
    private var dots: some View {
        HStack(spacing: Theme.Hangs.Spacing.xxs) {
            // `.hearing`: the same dots, brighter and a touch larger — the mic
            // is picking up speech right now.
            ForEach(Array((isHearing ? [1.0, 0.85, 0.7] : [1.0, 0.55, 0.3]).enumerated()), id: \.offset) { _, opacity in
                Circle()
                    .fill(accent)
                    .frame(width: isHearing ? 6 : 5, height: isHearing ? 6 : 5)
                    .opacity(opacity)
            }
        }
        .accessibilityHidden(true)
    }
}

/// #185 track F (F2): the halo around the answer bar, driven by the live mic
/// level. A separate view observing `RecordingInputLevel` so the ~47 Hz level
/// re-renders this ring alone, never the screen around it.
struct ListenBarLevelGlow: View {
    /// The ring and halo for one level — pure so the level → glow mapping is
    /// assertable without rendering.
    struct Glow: Equatable {
        /// How far the ring reaches outside the capsule.
        let ringWidth: CGFloat
        /// Halo (blurred shadow) opacity.
        let haloOpacity: Double
        /// Halo blur radius.
        let haloRadius: CGFloat

        /// 0 (quiet mic) → a thin, faint ring that still says "the mic is
        /// open"; 1 (loud voice) → a wide ring and a bright halo. Linear in
        /// between: the level is already dB-above-floor, i.e. perceptual.
        static func forLevel(_ level: Double) -> Glow {
            let l = min(max(level, 0), 1)
            return Glow(
                ringWidth: 2 + 10 * l,
                haloOpacity: 0.16 + 0.24 * l,
                haloRadius: 12 + 18 * l
            )
        }
    }

    /// Nil in previews and state tests: glows at the quiet level.
    let meter: RecordingInputLevel?
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let meter {
            ObservedGlow(meter: meter, color: color, reduceMotion: reduceMotion)
        } else {
            ring(Glow.forLevel(0))
        }
    }

    fileprivate func ring(_ glow: Glow) -> some View {
        Self.ring(glow, color: color)
    }

    fileprivate static func ring(_ glow: Glow, color: Color) -> some View {
        Capsule()
            .strokeBorder(color.opacity(0.16), lineWidth: glow.ringWidth)
            .padding(-glow.ringWidth)
            .shadow(color: color.opacity(glow.haloOpacity), radius: glow.haloRadius)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private struct ObservedGlow: View {
        @ObservedObject var meter: RecordingInputLevel
        let color: Color
        let reduceMotion: Bool

        var body: some View {
            // Reduce Motion: a steady ring — the status text still changes.
            let glow = Glow.forLevel(reduceMotion ? 0 : meter.level)
            ListenBarLevelGlow.ring(glow, color: color)
                .animation(.easeOut(duration: 0.12), value: glow)
        }
    }
}

#if DEBUG
    #Preview {
        VStack(spacing: 16) {
            ListenBar(mode: .command, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .command, commandHint: #"Say "start" or "skip""#,
                      thinkCountdown: .init(remaining: 32, total: 45))
            ListenBar(mode: .command, feedback: .matched, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .command, feedback: .unmatched, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .command, feedback: .hearing, commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .command, feedback: .recognizing,
                      recognizingWord: VoiceCommandLexicon.recognizingCaption(.skip),
                      commandHint: #"Say "start" or "skip""#)
            ListenBar(mode: .answer(.mcq))
            ListenBar(mode: .answer(.trueFalse), feedback: .unmatched)
            ListenBar(mode: .answer(.open))
            ListenBar(mode: .answer(.open), speechHeard: true)
            // #179 D1 — the question screen's four states, MCQ column.
            ListenBar(mode: .readingQuestion,
                      commandWords: ["„zopakuj“", "„preskoč“"], language: .slovak)
            // #189 — the confirmation sheet right after it opens.
            ListenBar(mode: .readingAnswerBack,
                      commandHint: "Povedz „potvrď“, „znova“ alebo novú odpoveď",
                      shortCaption: true, language: .slovak)
            ListenBar(mode: .command,
                      commandWords: ["„štart“", "„zopakuj“", "„preskoč“"],
                      language: .slovak,
                      thinkCountdown: .init(remaining: 32, total: 45))
            ListenBar(mode: .evaluating)
            ListenBar(mode: .skipping)
            ListenBar(mode: .command, commandHint: #"Say "start" or "skip""#, onDismiss: {})
            ListenBar(mode: .command, commandHint: #"Povedz „štart" alebo „preskoč""#, language: .slovak)
            ListenBar(mode: .command, commandHint: #"Say "start""#, size: .slim)
            ListenBar(mode: .command, feedback: .unmatched, commandHint: #"Povedz „štart""#,
                      size: .slim, language: .slovak)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Hangs.Colors.bg)
    }
#endif
