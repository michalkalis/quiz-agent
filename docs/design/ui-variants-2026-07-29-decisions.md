# UI-variant decisions — 2026-07-29 round (#131 Tracks D+F)

Founder picks, in-session 2026-07-29. Variant pages: `variants/issue-131D-result-hierarchy.html`, `variants/issue-131F-component-library.html`.

## #131 D — Result-screen hierarchy → **Variant A "Verdikt vládne"**

- Dominant verdict band on top (Anton, ~56pt scale), answer card second, all secondary meta (source, you-said, question recap) collapsed to ONE small muted mono row.
- State is said exactly once per screen: the small "správne / tesne vedľa" chip is dropped (the big verdict word already says it). Chip remains an available component in the library.
- Fixed (already shipped, not part of the pick): skipped = neutral "PRESKOČENÉ." verdict; footer = "Ďalšia otázka" primary left + ZOSTAŤ/POKRAČOVAŤ pill right; one ListenBar with command hint (`Povedz „ďalej"`).

## #131 F — Unified listening bar + component library → **Option B "full + slim"**

- ONE `ListenBar` component app-wide; `CmdListenBar` is retired everywhere (Home, Result, Confirmation adopt `ListenBar`).
- Two size variants of the same component: **full (~56pt)** on quiz screens (question, confirmation, result), **slim (~40pt)** on Home.
- All five bar states standardized: command (teal + hint sub-line) · answer (pink) · no-match corrective (amber + hint swap) · recording surface handoff (bar hidden, transcript card takes over — per #131 Track C) · unavailable.
- Token sheet on the F page (palette, Anton/Inter/mono scale, chips, cards, buttons) mirrors `Theme+Hangs.swift` and becomes the reference for the `.pen` component library (rule V1 continues: owning issue's component wins, others reuse).

## Pipeline

HTML picks (this doc) → Pencil sync (`design/quiz-agent.pen`: result frame per Variant A, bar consolidation per Option B, component library page; founder `⌘S`) → SwiftUI implementation.
