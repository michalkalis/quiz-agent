---
paths:
  - "apps/ios-app/**/*.swift"
---

# Swift & SwiftUI Implementation Rules (Trubbo iOS)

Companion to `ios-swiftui-layout.md`; project facts (schemes, localization, tests)
stay in `ios.md`. Distilled from the twostraws / AvdLee / Dimillian SwiftUI agent
skills and from review lessons on production SwiftUI apps. Swift 6 strict
concurrency, iOS 26+, MVVM with a service layer.

## 1. Files and structure

- One type per file. Organize by feature, not by kind, when adding new areas;
  keep existing folders (`Views/Components/Hangs`, `ViewModels`, `Services`)
  consistent rather than half-migrating.
- Member order in a view: `@Environment` → `@StateObject`/`@State`/`@Binding`
  → `let`/`var` inputs → `init` → `body` → view helpers → actions/helpers.
  Non-view computed vars above `init`, view helpers below `body`.
- No explanation comments; names carry the meaning. Doc comments only for
  non-obvious design or domain rules.
- `swiftformat` runs on every edit (PostToolUse hook); don't fight its output.

## 2. View models, state and side effects

- Keep the existing `ObservableObject` view models; don't introduce
  `@Observable` piecemeal. If a migration is ever wanted, it is one explicit
  task, not a by-product.
- `@State` and `@FocusState` are `private`. `@Binding` only where the child
  mutates parent state. Parent-owned inputs are never copied into `@State`.
- The view body reads like UI. Button actions reference methods
  (`Button("Save", action: save)`); business logic lives in view models and
  services, not in `.task`, `.onAppear`, `.onChange` or button closures.
- `QuizViewModel` state changes go through `transition(to:caller:)`; never
  set the state directly. Mirror that pattern for any new state machine.
- Stale-result races: a cancellable `Task` stored in the view model
  (`loadTask?.cancel()`, `try Task.checkCancellation()`,
  `guard !Task.isCancelled`), one `@discardableResult func load(...) -> Task<Void, Never>`.
  No generation counters, no `startLoad`/`performLoad` layering.
- User-interaction races: prevent, don't referee. Disable the control while the
  async work runs; don't add capture-and-revalidate logic. Derive guards from
  existing state before adding flags.
- Views never filter/sort/map inline in `body` or `init`; the view model
  publishes prepared arrays. `init` is a constant-time copy of inputs.
- `ForEach` needs stable ids from the model, never `\.self` on indices or
  `UUID()` created in `body`. `.sheet(item:)` over `.sheet(isPresented:)` when
  the sheet shows an entity.

## 3. API ergonomics

- Callbacks carry the entity (`(Question) -> Void`), not a `() -> Void`
  wrapped at the call site.
- Configure through the init with defaulted parameters, not post-construction
  `var` mutation. Defaults live in exactly one place.
- No `@MainActor` on members of an already-`@MainActor` class. No static
  factory that only wraps an initializer; prefer `lazy var` with inline
  construction when a child needs `self`'s properties.
- Names say what they return; a service method must not promise more than its
  request delivers.
- Container views take `@ViewBuilder let content: Content`, not a closure, so
  SwiftUI can diff the content.
- Repeated modifier chains (3+ uses) become a `ViewModifier` or a
  `ButtonStyle`/`LabelStyle`, exposed via static member lookup
  (`.buttonStyle(.hangsPrimary)`).

## 4. Swift language and concurrency

- `async`/`await` over closures; `Task.sleep(for:)`; no GCD
  (`DispatchQueue.main.async`) and no `Task.detached` without a strong reason.
  Strict concurrency: flag shared mutable state without an actor.
- No force unwrap / force `try` except truly unrecoverable paths. `if let value {`
  shorthand. `if`/`switch` as expressions; omit `return` in single expressions.
- `FormatStyle` (`.formatted(...)`, `Text(value, format:)`) over `DateFormatter`/
  `String(format:)`. `count(where:)` over `filter().count`.
  `localizedStandardContains` for user-typed filtering. `Date.now` over `Date()`.
- Static member lookup where it exists (`.rect(cornerRadius:)`, `.circle`,
  `.borderedProminent`). `foregroundStyle` over `foregroundColor`;
  `clipShape(.rect(cornerRadius:))` over `cornerRadius()`; `Tab` API over
  `tabItem`; `bold()` over `fontWeight(.bold)`.
- `.animation(_:value:)` always with a value. `onChange` two-parameter or
  zero-parameter form only. `@Animatable` macro over hand-written
  `animatableData`.
- Prefer `Double` over `CGFloat` except with optionals/inout.
- Errors from user actions surface in the UI; never swallow with a `print`.

## 5. Working style

- Research first: look for an existing component, modifier or pattern in the
  app before writing a new one; verify SwiftUI approaches against Apple
  docs/WWDC/established blogs. No first-idea workarounds.
- Readability over parallel-fetch micro-optimisations: sequential awaits unless
  the sequential version is measurably too slow (and then say so).
- Don't reshape working shared code while fixing something else; every changed
  line traces to the request (CLAUDE.md rule 1).
- Trust tester/reviewer bug reports; reproduce the state chain, don't argue from
  the code. Stay inside a review comment's scope.
- Before opening the PR: grep for helpers added earlier in the branch that are
  now orphaned and delete them; scan for redundant state sets the callee already
  does.
