# Design reference frames — `#52` screenshot-verify targets

Committed PNG exports of the `NEW_Screen/*` frames from `design/quiz-agent.pen`,
exported via the `pencil` MCP at 2x scale (2026-06-11). These are the **reference
images** the `#52` Ralph loop compares its simulator screenshots against — the loop
runs headless on `mba` with **no `pencil` MCP** (`.pen` is encrypted + the MCP needs
an interactive session), so the references must be pre-exported and committed here.

**Theme:** the `.pen` frames are **light mode only** (no dark-mode frames exist).
The loop self-checks light mode against these; **dark-mode fidelity stays a human
task** (`52.17`). Re-export after any `.pen` redesign: `pencil` MCP `export_nodes`
with `filePath: design/quiz-agent.pen`, `outputDir: docs/design/frames` (relative
paths — absolute fails), small batches (large batches error out).

| Frame PNG | Screen | `#52` task |
|-----------|--------|-----------|
| `rJ7dB.png` | Home | 52.8 |
| `Jjcs5.png` | Settings | 52.9 |
| `b8zObz.png` | Question — MultiChoice | 52.10 |
| `WCaT6.png` | Question — TrueFalse | 52.10 |
| `f9csl.png` | Question — Listen | 52.10 |
| `uGhZg.png` | Question — Capture | 52.10 |
| `X4o4l.png` | Result — Correct | 52.11 |
| `31AzE.png` | Result — Incorrect | 52.11 |
| `NPlqf.png` | Quiz-Complete | 52.12 |
| `gkeCn.png` | Onboarding 1 — Welcome | 52.13 |
| `hTdkE.png` | Onboarding 2 — Features | 52.13 |
| `haWJM.png` | Onboarding 3 — Permission | 52.13 |
| `COHnz.png` | Onboarding 3b — Denied | 52.13 |
| `Fwafe.png` | Error | 52.14 |
| `u2ySy.png` | Paywall | 52.15 |
| `PouwN.png` | Paywall — Offline | 52.15 |
| `vAXMX.png` | AnswerOption — 4-state reference | 52.3 |
