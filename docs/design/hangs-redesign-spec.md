# Hangs Redesign — Design Spec

Source: `untitled.pen` (Pencil file). 8 screens: Home, Quiz-Complete, Settings, Error, Question-Waiting, Question-Recording, Result-Correct, Result-Incorrect.

## Tokens

### Colors
- `cream` (app background) — `#F5F1E8`
- `ink` (primary text / near-black) — `#0E1A2B`
- `pink` (brand accent / primary CTA) — `#FF3D8F`
- `blue` (secondary accent / stat) — `#0A84FF`
- `muted` (subtext) — `#6B7280`
- `green` (success) — `#16A34A` (icon), `#22C55E` (check fill)
- `greenSoftBg` — `#22C55E1F`
- `pinkSoftBg` — `#FF3D8F1F` / `#FF3D8F14` (outer pulse) / `#FF3D8F26` (middle pulse) / `#FF3D8F33` (button shadow)
- `cardWhite` — `#FFFFFF`
- `hairline` — `#0E1A2B14` (dividers, 8% ink)
- `subtleBorder` — `#0E1A2B1F` (button border)
- `mutedBorder` — `#0E1A2B1A`
- `incorrectAnswerText` — `#9CA3AF` (struck-out)

### Typography
- `Anton` — display (HANGS, COMPLETE, OOPS, NAILED IT, CLOSE—BUT NO, question text, score). Sizes: 80 hero, 72 big, 62 headline, 44 stat, 40 question-waiting, 32/30 answer, 26/28 medium, 22 sub-hero.
- `IBM Plex Mono` — labels/micro-caps. Sizes: 11 (letterSpacing 2) for section labels, 13 for brand word & counter, 17 for brand logo, 14 for version.
- `Inter` — body & buttons. Sizes: 17 button, 16 row label, 15/14 sub, 13/12 meta. Weights: 500, 600, 700.

### Shadows
- `cardShadow`: blur 20, offset (0,4), `#0E1A2B14`
- `navButtonShadow`: blur 8, offset (0,2), `#0E1A2B0F`
- `ctaShadow`: blur 16, offset (0,6), `#FF3D8F33` (primary) / `#FF3D8F40` (stop-recording)
- `micShadow`: blur 24, offset (0,8), `#FF3D8F4D` / `#FF3D8F66`

### Radii
- Card: 18 / 16 (inner)
- CTA button: 28–32
- Nav icon button: 10 (home back/close), 18 (in-quiz close chip)
- Pill label: 14
- Mic pulses: `cornerRadius == height/2` (circular)

### Spacing / screen layout
- Screen bg `cream`. Status bar + brand row at top.
- Screen H padding 20 (Home, Complete, Settings, Error) or 24–28 (Question/Result flows).
- Cards span full width with 12–20 vertical rhythm.
- Bottom CTA has ≥20pt bottom safe-area inset.

## Component Library (from designs)

| Pencil ref | Role | Notes |
|---|---|---|
| `StatusBar` | iOS status bar | Normally hidden on real device — skip custom. |
| `Divider` | 1pt hairline | `hairline` color, fills row width. |
| `FooterBar` | bottom CTA area | Uses `Button/Primary` + optional ghost link. |
| `Button/Primary` | pink filled 64pt tall cta | Icon+label, `ctaShadow`, radius 32. |
| `Button/Secondary` | white bordered 52–56pt | `subtleBorder` stroke, radius 28. |
| `Button/Ghost` | inline text button | Blue, icon+label, no bg. |
| `Card` | white rounded 18pt card | `cardShadow`. |
| `StatBox` | white card, label + big number | Used for streak/best/points. |
| `ConfigRow` | tappable row, label + value + chevron | Used in Home session + Settings. |
| `QuestionCard` | vertical pink-bar + Anton question text | Used in Question screens. |
| `MicButton/Large` | 148pt pink mic w/ 2 pulse rings (200, 260) | Waiting state. |
| `MicButton/Small` | 130pt pink mic w/ waveform + 2 pulse rings (180, 240) | Recording state. |
| `ProgressCounter` | 03 / 10 monospace + top 3pt bar | Header in quiz flow. |
| `ScoreCounter` | big Anton number | Used in Complete & Result. |
| `ResultBanner/Correct` | green pill "CORRECT" | Uses check icon. |
| `ResultBanner/Incorrect` | pink pill "NOT QUITE" | Uses x icon. |

## Screens

### 1. Home (`NEW_Screen/Home`)
- Brand row: `hangs.` (blue Plex Mono 17) + pink 6pt dot • right gear button (36pt, white, radius 10, nav shadow, settings lucide icon).
- Hero: `HANGS` Anton 80 ink, pink 40×2 underline, sub "voice-based trivia for the road" Inter 14 muted.
- Stats row: two equal cards side-by-side (streak pink label / blue 44 number; best blue label / pink 44 number). Gap 12.
- "session" pink Plex Mono 11 label.
- ConfigCard (white radius 18, card shadow): 3 rows separated by `hairline`: Language→English (blue) → chev; Difficulty→Medium (pink)→chev; Categories→All (blue)→chev. Row padding 16v/18h.
- CTA: pink `Start Quiz` button 64pt, play icon + text, radius 32, cta shadow.

### 2. Quiz-Complete (`NEW_Screen/Quiz-Complete`)
- Brand row + close (x) button right.
- Hero: `COMPLETE` Anton 62 + underline + sub "nice work — here's your run".
- Final score card: "final score" pink mono → `87` Anton 80 ink centered → "out of 100" muted 13.
- Breakdown card: 3 rows (Correct 8 blue Anton 28 / Incorrect 2 pink / Avg points 8.7 blue), with hairline dividers.
- CTA stack: Pink `Play Again` rotate-ccw icon (58pt), secondary white `Home` house icon (52pt, bordered).

### 3. Settings (`NEW_Screen/Settings`)
- Brand row + left-arrow back button right.
- Hero: `SETTINGS` Anton 62 + underline + sub "tune your experience".
- 4 grouped cards with section mono labels (alternating pink / blue):
  1. `voice`: Voice commands (toggle pink on), Wake word → `hey hangs` (blue) chev.
  2. `language`: Current language → `English` (pink) chev.
  3. `audio feedback`: Speak scores aloud (toggle off, muted bg).
  4. `about`: Version `1.0.0` (right, muted Plex Mono).

### 4. Error (`NEW_Screen/Error`)
- Brand row (no right action; 36pt spacer to balance).
- Large round pink-soft bg 128pt with triangle-alert pink 56pt icon.
- Hero: `OOPS` Anton 72 centered + pink 40×2 underline + `Something went wrong` Inter 17 centered.
- Body: muted 14 centered 1.5 line-height with 28pt side padding.
- CTA stack: Pink `Try Again` rotate-ccw (64pt), secondary `Go Home` house (56pt).

### 5. Question-Waiting (`NEW_Screen/Question-Waiting`)
- Top: small status bar-like row (time / ellipsis).
- Nav row: close chip (36pt radius 18) + inline `hangs` brand. Right: `03 / 10` counter Plex Mono 13 muted.
- Progress bar: 3pt pink filled + `mutedBorder` remainder.
- Hero: `GEOGRAPHY` pink mono label.
  - Question line: 3pt blue vertical bar (height ≈ text) + Anton 40 ink question text, `lineHeight 1.05`, `letterSpacing -1`. **Must be fill_container width and wrap; parent ScrollView when long.**
  - Sub copy: "Answer out loud when the mic glows." muted 14.
- Mic area (fill remaining vertical): 3 concentric circles (260 outer pink@8%, 200 middle pink@20%, 148 pink solid mic; mic lucide icon white 56). `Tap to speak` Anton 22 + "or say "start" to begin" muted 13.
- Footer: white `Skip question` secondary button 54pt.

### 6. Question-Recording (`NEW_Screen/Question-Recording`)
- Same top / nav layout; right has pink dot + `0:04` timer.
- Hero smaller: mono `GEOGRAPHY · QUESTION 3` blue + pink bar + Anton 26 question. **Still scrollable if long.**
- Transcript card (white, radius 16, card shadow): `LISTENING` pink mono + "I think it's Paris…" Inter 17.
- Mic area: 240/180/130 rings, 7 white waveform bars (heights 22,44,62,36,50,28,18), `Listening…` Anton 22, "say "stop" when finished" muted 13.
- Footer: pink `Stop recording` (60pt, square icon + text).

### 7. Result-Correct (`NEW_Screen/Result-Correct`)
- Top sb + nav (close + brand + `03/10`) + progress bar (pink ≈ 117pt filled).
- Hero: green `CORRECT` pill with check (radius 14, greenSoftBg) → `NAILED\nIT.` Anton 72 line-height .95 → "+ 100 points · streak now 48" muted.
- Answer card: header row "YOUR ANSWER" blue mono + green 24×24 check badge. Big `Paris` Anton 32. Hairline. "THE QUESTION" pink mono + question Inter 15 muted wrap.
- Stats row: Streak (blue label, blue 36 + `+1` muted) / Points (pink label, pink 36 + `+100`).
- Flex spacer pushes footer down.
- Footer: pink `Next question` 64pt w/ arrow + ghost "Why is this correct?" book-open blue.

### 8. Result-Incorrect (`NEW_Screen/Result-Incorrect`)
- Top sb/nav/progress same.
- Hero: pink `NOT QUITE` pill with x. `CLOSE—\nBUT NO.` Anton 58 line-height .95. Sub "streak reset · still worth the try".
- Answer card: "YOU SAID" pink mono + pink 20×20 x badge → `Lyon` Anton 26 `#9CA3AF` (muted strikethrough effect). Hairline. "THE ANSWER" blue mono + blue 20 check badge → `Paris` Anton 30 ink.
- Stats: Streak 0 "was 47" / Points 2.3k "+0".
- Footer: pink `Next question` 60pt + ghost "Try this question again" rotate-ccw blue.

## Implementation notes
- Keep a global `HangsTheme` enum with `Color`/`Font` tokens. Use `Font.custom("Anton")` etc. — bundle Anton + IBM Plex Mono + Inter via `UIAppFonts`.
- Question text must be inside a `ScrollView` that can grow up to a max height; mic area below compresses to a minimum height. On very long questions, user can scroll the question without losing the mic.
- Preserve all existing behaviour wiring from `QuizViewModel` — only swap view structure.
