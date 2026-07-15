# #97 — CarPlay support

**Triage:** enhancement · needs-triage
**Status:** Captured 2026-07-15 (founder ask — "fairly high priority"). Not yet planned; run `/prepare-issue` to scope before any agent run.

## Why

The core product is voice-first, hands-free trivia **while driving**. Today the app runs only as a phone app; the driver's real surface is the car's head unit. Native CarPlay integration puts the quiz on the car screen with driving-safe UI, which is directly on the product vision (see `CONTEXT.md`).

## To scope (prep questions, not decisions yet)

- **CarPlay entitlement** — Apple gates CarPlay behind a per-app entitlement request (developer.apple.com). Which template family fits: audio app, or a custom/communication template? Voice-first quiz is an unusual fit for the stock CarPlay templates (list/grid/now-playing), which are deliberately constrained for driver safety.
- **Voice flow mapping** — how the existing SpeechAnalyzer voice-command + TTS loop maps onto CarPlay's audio session and template constraints; whether the quiz can run purely audio (now-playing style) with the phone driving speech, or needs on-screen templates.
- **Apple review** — CarPlay apps face extra review + the entitlement approval step (can be slow); flag as a `[HUMAN]`/external-dependency gate.
- **Scope split** — likely an audio-first MVP (question TTS + voice answers over the car speakers, minimal screen) vs. a fuller templated UI later.

## Links

- Product vision / driving use case: `CONTEXT.md`
- Existing voice stack: #77 (voice commands), #45 (MCQ voice)
