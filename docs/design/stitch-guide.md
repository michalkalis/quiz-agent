# Google Stitch Design Guide — CarQuiz

Use [Google Stitch](https://stitch.withgoogle.com) to explore and elevate CarQuiz's visual design. Stitch generates high-fidelity mobile UI from text prompts and exports to Figma and HTML/CSS.

**Key constraint:** Stitch does NOT export SwiftUI code. It's a **visual design exploration** tool — use it for inspiration, then implement in SwiftUI manually or with Claude Code using the designs as reference.

---

## Workflow

```
1. Open stitch.withgoogle.com
2. Use prompts below (one screen at a time)
3. Generate 2-3 variants per screen → pick best
4. Iterate with follow-up prompts (one change at a time)
5. Export to Figma (Standard mode → Copy to Figma)
6. Use as visual reference when implementing SwiftUI updates
```

---

## CarQuiz Design System Context

These tokens are used in prompts to keep Stitch output consistent with the app:

| Token | Value |
|-------|-------|
| Accent color | Purple `#8B5CF6` |
| Platform | iOS 26, Liquid Glass |
| Fonts | SF Pro, SF Pro Rounded (headings) |
| Icons | SF Symbols only |
| Mode | Dark mode primary |
| Min touch target | 44pt (56pt for driving screens) |
| Margins | 16pt standard iOS |

---

## Screen Prompts

Generate **one screen at a time** — multi-screen prompts degrade quality.

### Screen 1: Home / Lobby

```
Design a native iOS 26 app home screen for a trivia quiz app called "CarQuiz". Follow Apple Human Interface Guidelines strictly. Use the iOS 26 Liquid Glass design language.

Platform: iPhone, portrait, iOS 26. Use SF Pro font, SF Symbols icons, native iOS components only.

Navigation: Large title navigation bar with "CarQuiz" title using iOS Liquid Glass translucent material.

Content (scrollable, grouped inset list style):
- Hero section at top: A large rounded rectangle with a subtle purple-to-indigo gradient background. Inside: a brain/lightbulb SF Symbol icon (large, white), app tagline "Hands-free trivia" in SF Pro Rounded bold, and a prominent "Start Quiz" button using iOS filled button style with purple tint.
- "Quick Setup" section (grouped inset list, Liquid Glass material cards):
  Row 1: Globe icon in blue circle + "Language" label + "English" value + chevron
  Row 2: Gauge icon in orange circle + "Difficulty" label + iOS segmented control (Easy | Medium | Hard)
  Row 3: Number icon in green circle + "Questions" label + iOS stepper showing "10"
- "Your Stats" section (grouped inset list):
  Row 1: Flame icon in red circle + "Daily Streak" + "7 days"
  Row 2: Chart icon in purple circle + "Quizzes Today" + "3 of 5"
  Row 3: Trophy icon in gold circle + "Best Score" + "9/10"

Bottom: iOS 26 floating tab bar with Liquid Glass material. Three tabs: Home (house.fill, selected), History (clock.fill), Settings (gear).

Colors: Purple (#8B5CF6) as tint/accent color. Use iOS system background colors (systemBackground, secondarySystemGroupedBackground). Support dark mode — show the dark mode variant. All icons use SF Symbols. Spacing follows iOS 16pt margins. Touch targets minimum 44pt.
```

---

### Screen 2: Quiz Question (Voice Mode)

```
Design a native iOS 26 quiz question screen for a voice-first trivia app. Apple Human Interface Guidelines, Liquid Glass design language.

Platform: iPhone, portrait, iOS 26. SF Pro font, SF Symbols icons.

Navigation bar: Compact inline title "Question 3 of 10" with Liquid Glass material. Left: X button (xmark) to close. Right: small category tag "Geography" in a capsule shape with purple tint.

Main content (centered vertically):
- Top: Thin iOS-native progress bar (ProgressView style) showing 30% complete, purple tint
- Center: Large card with iOS grouped inset background. Inside the card:
  - Small label "QUESTION 3" in caption style, secondary text color
  - Large question text "What is the capital of Australia?" in title2 weight bold, primary text color
  - Generous padding (24pt inside card)
- Below card: Small "Listening..." label with a green pulsing circle indicator (like iOS voice memo recording indicator)

Bottom section (pinned to bottom, above safe area):
- A VERY LARGE circular button (140pt diameter) centered horizontally
- The button has a purple (#8B5CF6) fill with a microphone SF Symbol (mic.fill) in white, 40pt size
- Subtle shadow/glow around the button
- Below button: caption text "Tap or just speak" in secondary color

The mic button must be the dominant element — this app is used while driving. Keep the screen minimal and glanceable. Large text, few elements, maximum readability. Use iOS system colors and materials. Dark mode variant.
```

---

### Screen 3: Quiz Question (Multiple Choice)

```
Design a native iOS 26 multiple choice quiz screen. Apple Human Interface Guidelines, Liquid Glass design language.

Platform: iPhone, portrait, iOS 26. SF Pro font, SF Symbols.

Navigation bar: Inline title "Question 5 of 10" with Liquid Glass. Left: X close button. Right: category capsule "History" in purple.

Content:
- Progress bar at top (ProgressView, 50% filled, purple tint)
- Question card (grouped inset background, generous padding):
  "Which country has the longest coastline?"
  Title2 bold, primary color

- Answer options below the card — 4 buttons stacked vertically with 12pt spacing:
  Each option is a full-width rounded rectangle (iOS grouped inset row style, minimum 56pt tall):
  - Left: Letter in a small circle (A, B, C, D) using secondaryLabel color
  - Center: Answer text in body font, left-aligned
  - Unselected state: secondarySystemGroupedBackground fill, subtle border
  - Selected state: Purple (#8B5CF6) tinted background, purple border, checkmark on right

  Options:
  A) Canada (selected state — show this one highlighted with purple tint and checkmark)
  B) Indonesia
  C) Russia
  D) Australia

- Bottom bar pinned: "Skip" text button on left (secondary color), "Confirm" filled button on right (purple, disabled until selected). Use iOS button styles.

Large touch targets (56pt rows). Dark mode. iOS system colors.
```

---

### Screen 4: Answer Result

```
Design a native iOS 26 answer result screen for a trivia app. Apple Human Interface Guidelines.

Platform: iPhone, portrait, iOS 26. SF Pro font, SF Symbols.

Navigation bar: Inline "Question 3 of 10" with Liquid Glass. Right: "250 pts" in a small capsule.

Content (centered, scrollable):
- Large result indicator at top center:
  A circle (80pt) with green (#34C759, iOS system green) fill, white checkmark.circle.fill SF Symbol inside. Below: "Correct!" in title2 bold green, and "+100 pts" in headline weight.

- Two comparison cards (grouped inset list style):
  Section 1 header: "YOUR ANSWER" in caption, secondary color
  Row: "Canberra" with a green checkmark icon on the right

  Section 2 header: "CORRECT ANSWER" in caption, secondary color
  Row: "Canberra" with green checkmark

- Fun fact card (grouped inset, subtle green tint border):
  "Canberra was chosen as the capital in 1908 as a compromise between Sydney and Melbourne."
  In callout font, secondary text color. Small lightbulb SF Symbol icon at top-left.

- Rating row: "Rate this question" label + 5 star icons (star.fill / star) in a horizontal row, yellow tint

- Bottom pinned: Full-width "Continue" filled button, purple tint, iOS button style.

Show the CORRECT answer variant (green positive feedback). Make it feel rewarding and educational. Dark mode. iOS system colors and materials.
```

---

### Screen 5: Quiz Complete / Summary

```
Design a native iOS 26 quiz completion screen for a trivia app. Apple Human Interface Guidelines.

Platform: iPhone, portrait, iOS 26. SF Pro font, SF Symbols.

No navigation bar — this is a full-screen celebration view.

Content (centered vertically, scrollable):
- Top: Large trophy SF Symbol (trophy.fill) in 60pt, with a gold/yellow (#FFD60A) color. Subtle warm glow behind it.
- Title: "Quiz Complete!" in largeTitle bold
- Subtitle: "Great job!" in title3, secondary color

- Score circle: A circular progress ring (120pt diameter), 80% filled in purple (#8B5CF6). Inside: "8/10" in title1 bold, "80%" below in subheadline secondary color.

- Stats section — 2x2 grid of cards (grouped inset style, each card equal size):
  Top-left: Checkmark icon (green) + "8" large + "Correct" caption
  Top-right: Xmark icon (red) + "2" large + "Missed" caption
  Bottom-left: Flame icon (orange) + "5" large + "Best Streak" caption
  Bottom-right: Star icon (purple) + "750" large + "Points" caption
  Each card has subtle rounded border, iOS secondarySystemGroupedBackground.

- Bottom section with 16pt spacing:
  "Play Again" — full-width filled button, purple tint
  "Back to Home" — full-width plain/text button style, secondary color

Celebratory but tasteful — no confetti or over-the-top effects. Clean iOS native feel. Dark mode.
```

---

### Screen 6: Settings

```
Design a native iOS 26 settings screen. Follow Apple Human Interface Guidelines exactly — this should look identical to the iOS Settings app in style.

Platform: iPhone, portrait, iOS 26. SF Pro font, SF Symbols. Liquid Glass navigation bar.

Navigation bar: Large title "Settings" with Liquid Glass material. Back button on left.

Grouped inset list (Form style), scrollable:

Section "QUIZ":
- Row: Globe icon in blue circle + "Language" + "English 🇬🇧" + chevron (navigation link style)
- Row: Number.circle icon in green circle + "Questions" + iOS Picker/Menu showing "10" (options: 5, 10, 15, 20)
- Row: Gauge.medium icon in orange circle + "Difficulty" + inline segmented control: Easy | Medium | Hard | Mixed
- Row: Tag icon in purple circle + "Categories" + "All" + chevron

Section "VOICE & AUDIO":
- Row: Mic icon in indigo circle + "Voice Commands" + iOS Toggle (on)
- Row: Record.circle icon in red circle + "Auto-Record After Question" + iOS Toggle (on)
- Row: Waveform icon in teal circle + "Barge-in" + iOS Toggle (on) + info.circle button
- Row: Speaker.wave.2 icon in gray circle + "Audio Output" + "iPhone Speaker" + chevron

Section "GENERAL":
- Row: Star icon in yellow circle + "Rate CarQuiz"
- Row: Lock.shield icon in blue circle + "Privacy Policy" + chevron
- Row: Info.circle icon in gray circle + "Version" + "1.0.0" (detail text, no chevron)

Each icon should be in a small colored rounded square (like iOS Settings). Use iOS system grouped background colors. Standard 44pt row height. Separator insets matching iOS standard. Dark mode variant.
```

---

### Screen 7: Onboarding (Page 1 of 3)

```
Design the first page of a native iOS 26 onboarding flow for a trivia app called "CarQuiz". Apple Human Interface Guidelines.

Platform: iPhone, portrait, iOS 26. SF Pro Rounded for headings, SF Pro for body.

This is page 1 of a 3-page onboarding carousel.

Layout (vertically centered):
- Top 40% of screen: Large SF Symbol illustration — car.fill inside a rounded rectangle with a purple-to-indigo gradient background. The icon should be 80pt, white. The container should be about 200x200pt with 32pt corner radius.

- Center text block:
  Title: "Welcome to CarQuiz" in largeTitle bold (SF Pro Rounded)
  Subtitle: "The hands-free trivia game you can play anywhere" in body, secondary text color. Max 2 lines, center-aligned.

- Bottom section (pinned above safe area):
  Page indicator dots: 3 dots, first filled (purple), others unfilled (tertiary color)
  16pt below dots: Full-width "Continue" filled button, purple tint
  8pt below: "Skip" plain text button, secondary color

Clean, welcoming, minimal. Plenty of whitespace. iOS system background color. Dark mode variant. No custom illustrations — SF Symbols only.
```

---

### Screen 8: Paywall / Upgrade

```
Design a native iOS 26 paywall sheet for a trivia app. Apple Human Interface Guidelines. This appears as an iOS sheet (not full screen) — show it as a modal card with a drag indicator at top.

Platform: iPhone, portrait, iOS 26. SF Pro font, SF Symbols.

Sheet content:
- Drag indicator bar at very top (standard iOS sheet grabber)
- X close button in top-right corner

- Center icon: Lock.open.fill SF Symbol (48pt) in a circle with purple gradient fill, white icon

- Title: "You've hit today's limit" in title2 bold, center-aligned
- Subtitle: "Free players get 5 quizzes per day" in subheadline, secondary color

- Countdown: clock.fill SF Symbol + "Resets in 14h 32m" in a capsule/pill shape with tertiarySystemFill background

- Comparison card (grouped inset style):
  Header row: "Free" column | "Pro" column
  Row 1: "Daily quizzes" | "5" | "Unlimited" (with checkmark, green)
  Row 2: "Categories" | "Basic" | "All" (with checkmark, green)
  Row 3: "Voice priority" | xmark (red) | checkmark (green)
  Use SF Symbols checkmark.circle.fill (green) and xmark.circle.fill (red).

- Bottom:
  "Upgrade to Pro — $4.99/mo" large filled button, purple tint, full width
  "Restore Purchases" plain text button below, secondary color

Encouraging tone, not punishing. iOS native materials and colors. Dark mode.
```

---

## Iteration Prompts

Use these after initial generation to refine:

**iOS 26 native feel:**
```
Make this more native iOS 26 — use Liquid Glass translucent materials for the navigation bar and tab bar. Use only SF Symbols for icons. Match the exact spacing and typography of Apple's built-in apps.
```

**Dark mode:**
```
Switch to dark mode. Use iOS systemBackground (#000000) and secondarySystemGroupedBackground for cards. Ensure all text meets WCAG AA contrast (4.5:1 minimum).
```

**Driving-safe sizing:**
```
The buttons need to be larger — this app is used while driving. Make all interactive elements at least 56pt tall. Increase question text to 22pt minimum. Reduce the number of visible elements.
```

**Mic button emphasis:**
```
Make the mic button more prominent — 160pt diameter, stronger purple glow shadow, and add a subtle ring animation effect around it to indicate it's the primary action.
```

**iOS Settings style:**
```
Use the exact iOS grouped inset list style for this screen — matching Apple Settings app: 20pt horizontal margins, standard row height 44pt, SF Symbol in colored rounded square on left, separator inset at 56pt from leading edge.
```

---

## Export Workflow

### Stitch → Figma → SwiftUI Reference

1. **In Stitch** (Standard mode, 350 gen/month):
   - Generate screen, iterate until happy
   - Click the design → click "Copy to Figma"

2. **In Figma:**
   - Paste (Cmd+V) — arrives with Auto Layout, named layers
   - Organize into frames: "Home", "Question-Voice", "Question-MCQ", "Result", etc.
   - Refine: adjust for iOS safe areas, Dynamic Type, accessibility

3. **In Claude Code:**
   - "Look at the Figma/Stitch design for [screen] and update the SwiftUI implementation"
   - Or save a screenshot and use `/review-ui` to get SwiftUI improvement suggestions

### Stitch MCP (Optional Future Setup)

If you later add the Stitch MCP server to `.mcp.json`:
```json
"stitch": {
  "command": "npx",
  "args": ["@_davideast/stitch-mcp", "proxy"]
}
```

Prerequisites: run `npx @_davideast/stitch-mcp init` to configure your API key.

Then you can ask Claude Code directly:
```
"Use Stitch to design the quiz question screen for CarQuiz"
```
Claude Code generates via MCP → fetches screenshot → can implement SwiftUI to match.