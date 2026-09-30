---
paths:
  - "apps/ios-app/**/*.swift"
---

# SwiftUI Layout Rules (Trubbo iOS)

Goal: layouts that read as rules, not as numbers. Let SwiftUI's propose → size → place
algorithm do the work; every constant must name the rule it stands for. Sources:
Apple HIG Layout, WWDC22 10056 (custom layouts), WWDC23 10159 (scroll views),
WWDC25 323 (new design), WWDC26 Group Lab, AvdLee/twostraws SwiftUI agent skills.
Target is iOS 26+, so every API below is available without gating.

## 1. Sizing: never measure what the layout system already knows

- **Never** `UIScreen.main.bounds`. The screen is not the container (iPad Split
  View, Stage Manager, sheets, previews). Size from the proposed size.
- **GeometryReader is the last resort.** It swallows the proposed size and feeds
  measurements upward (layout loops, refresh-task cancellation). Preference order:
  `ViewThatFits` → `containerRelativeFrame` → `onGeometryChange` → `visualEffect`
  → `Layout` protocol → GeometryReader. If you still need it, put it in
  `.background`/`.overlay` so it doesn't affect layout, and never let measured
  geometry write `@State` that changes the layout of the same hierarchy.
- **No fixed frames on content.** `.frame(height: 150)` breaks on Dynamic Type,
  iPad and longer localized strings. Use flexible bounds (`maxWidth: .infinity`,
  `minHeight:` as a floor) and let content define its own height. Fixed sizes are
  fine for icons, illustrations with a known aspect ratio and design slot sizes.
- Space contests: `fixedSize(horizontal: false, vertical: true)`,
  `layoutPriority`, `lineLimit`. Never width arithmetic.
- Full width: `.frame(maxWidth: .infinity, alignment: .leading)`, not
  `HStack { Text; Spacer() }`.

## 2. Numbers: tokens, and a rule behind every constant

- Spacing/padding from `Theme.Hangs.Spacing`, radii from `Theme.Hangs.Radius`,
  shadows from `Theme.Hangs.Shadow`, colors from `Theme.Hangs.Colors`. An inline
  `13` or `26` is a bug unless it is a documented design input.
- `Utilities/Theme.swift` is the app's only token set (#188). Its `Palette` is
  file-private base values; views use the semantic tokens only. A missing token
  is added there (semantic name → palette value), never as `Color(hex:)` or a
  system color in a view.
- Before adding a constant ask "what rule is this number faking?" A pager height
  fakes "as tall as the tallest page"; asymmetric top/bottom padding fakes
  "centred, slightly above the middle". Express the rule (Spacer ratios,
  alignment, `minHeight` floor) instead.
- Values that are real design inputs from the `.pen` source (illustration box,
  CTA width, mic button size) live in a small `private enum Metrics` in the view.
  Keep it short; it is not a dumping ground for paddings.
- Fonts through the `.hangs*` font helpers (`.hangsBody`, `.hangsDisplay`,
  `.hangsMono`, `.hangsNumberLG`, …), never a raw `.font(.system(size:))` in new
  code. Prefer semantic text styles or `@ScaledMetric` wherever the design allows
  so Dynamic Type works; the app is used in a car, larger text matters.
- Minimum tap target 44×44pt (HIG); voice-first screens get bigger. Add
  `.contentShape(.rect)` on tappable rows with transparent backgrounds.

## 3. Adaptivity: size classes, never device idiom

- The target is universal (iPhone + iPad). Layout decisions come from
  `horizontalSizeClass`/`verticalSizeClass`, `ViewThatFits`, `AnyLayout`
  (`VStackLayout` ⇄ `HStackLayout`) and `containerRelativeFrame`. Never
  `userInterfaceIdiom` or orientation checks; they don't reflect the space the
  view actually gets.
- Views are context-agnostic: they must work as full screen, sheet, popover and
  embedded. Never assume presentation style.
- Custom views own their static container (`VStack`/`HStack`); the caller owns
  lazy/repeatable containers (`LazyVStack` + `ForEach`).
- Horizontal pagers (`TabView(.page)`, horizontal `ScrollView`) are edge-to-edge;
  padding goes inside each page, otherwise pages clip while swiping.
- Liquid Glass: don't paint custom backgrounds under bars, sheets and toolbars.
  Use `safeAreaBar` for custom bars, `GlassEffectContainer` + `glassEffectID`
  for grouped glass, `backgroundExtensionEffect` for edge-to-edge hero content.

## 4. Scroll containers and safe areas

- Insets on scroll content: `.contentMargins` / `.safeAreaPadding`, not
  `.padding()` on the `ScrollView` (it clips content while scrolling).
- Bars pinned to an edge: `.safeAreaInset(edge:)` / `safeAreaBar`, not a ZStack
  with manual bottom padding.
- Pull-to-refresh belongs on `List` + `.refreshable`; ScrollView's refresh task
  is cancelled by state mutations during the refresh. Commit state in one batch
  at the end.
- `List` for long data. `LazyVStack` in `ScrollView` only when you need scroll
  position or visual-effect control. Plain `VStack` for small static content.
- `scrollTargetBehavior`, `scrollPosition`, `defaultScrollAnchor`,
  `scrollTransition` over `ScrollViewReader` and offset math.

## 5. Composition: flat, stable and dumb

- **Mirror the nearest existing view** of the same complexity (`rg` for a
  similar component under `Views/Components/Hangs`) before inventing structure.
  A plain struct with a few parameters beats a generic layout wrapper used by
  three screens. No new shared layout abstractions without asking.
- `body` composes named sections. Extract a real `View` struct (own file when
  independently meaningful) when a section has its own state, async work,
  appears in a `ForEach`, is reused, or when `body` no longer fits one screen.
  Small private `some View` helpers are fine; a screen built entirely out of
  `private var header: some View` fragments is not. Only a separate `View` type
  is an invalidation boundary; `@ViewBuilder` helpers are not.
- Extracted subviews get small explicit inputs (values, bindings, typed
  callbacks carrying the entity), not the whole view model.
- Decoration goes in `.overlay`/`.background`; `ZStack` only when peers must
  participate in sizing. `.compositingGroup()` before `.clipShape` on layered views.
- Stable tree: prefer inert modifiers (`opacity`, `disabled`, `.toolbar { if }`)
  over top-level `if/else` that swaps whole screens (identity churn, lost
  `@State`). Never duplicate a view body to attach a conditional gesture.
- No `AnyView`. No single-child `Group { X }`. `Label` over
  `HStack { Image; Text }`. `Button` over `onTapGesture`. `ContentUnavailableView`
  over hand-built empty states. Hierarchical styles (`.secondary`) over
  `.opacity` hacks.
- Never reserve fixed-height slots for content whose count can change (buttons,
  text lines). Anchor with a Spacer or `.frame(minHeight:, alignment: .bottom)`.
- A reusable rule with an odd shape (1:2 free-space split, two trailing Spacers)
  gets a name (small `View` extension) rather than being copy-pasted.

## 6. Verify before claiming done

- Build (`xcodebuild -scheme Hangs-Local …`, see `ios.md`) and check the result
  on iPhone and iPad, portrait and landscape, and with a larger text size.
  Simulator driving goes through the `ios-ui-driver` subagent, never the main
  session. Swipe pagers and rotate; a static screenshot is not verification.
- Design fidelity against the `.pen` frames is a non-gating check (see
  "Verification Altitude" in `ios.md`); flow and state tests are the gate.
- When unsure whether a SwiftUI approach is sound, verify against Apple docs,
  WWDC sessions or established sources before building. No invented workarounds.
