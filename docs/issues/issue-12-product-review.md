# Issue #12: Product Review of Quiz App

## Status: DONE

## Deliverable
Full product review written to `docs/research/product-review.md` (2026-04-03).

## Summary of Findings
- 19 new issues identified beyond the original 13
- 2 P0 issues: voice commands English-only, no audio cue for recording start/stop
- 5 P1 issues: no "next" voice command, session expiry UX, 60s thinking time default, hardcoded English TTS locale, missing explanation TTS
- 6 P2 issues: mute breaks driving UX, history cap with no rotation, completion stats bugs, rating UX, session resume broken
- 6 P3 issues: haptic feedback, premium auth broken, cache bypass, partial score display, help command limited, audio session reactivation

## Top 5 Recommendations
1. Add recording start/stop audio cues (XS effort, highest impact)
2. Reduce default thinking time from 60s to 10-15s
3. Implement multilingual voice commands (Slovak keywords + locale switching)
4. Add "next" voice command for result screen
5. Implement explanation TTS for incorrect answers

## Multiplayer Readiness
Backend is ~60% ready (participant model, endpoints exist). iOS needs WebSocket layer, lobby UI, leaderboard, turn logic. Estimated 3-4 weeks for basic 2-player mode.
