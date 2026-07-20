# Issue 116: Split AudioService into focused audio units

**Triage:** refactor · needs-triage
**Reversibility:** a
**Status:** Created by /prepare-issue 2026-07-20 from the iOS architecture review 2026-07-18 — Top 10 item 7. Prep pipeline running on branch `arch-review-ios`.
**Created:** 2026-07-20

**Source:** [iOS architecture review 2026-07-18](../research/ios-architecture-review-2026-07-18.md) — Top 10 item 7 + dimension 7. Link, don't restate.

## Why (stub — Phase 2 expands)

AudioService conflates session config/routing/interruptions, input-device management, batch M4A recording, streaming PCM recording, and AVPlayer playback+stall-handling in one 1,246-line class (`AudioService.swift:71`; `startStreamingRecording` alone is 133 lines). Review direction: split into **AudioSessionManager, AudioDeviceManager, BatchRecorder, StreamingPCMRecorder, AudioPlaybackService** behind the existing protocol facade.

**Caution:** this file just absorbed the #104 — car-audio session fixes (media/call mode, SCO stability, teardown race) and #106 — TTS stall timer; the split must be behavior-preserving and lean on the existing tests from that run. Founder on-device car legs for #104 are still pending — coordinate timing so the split doesn't invalidate an unverified build.

## Prep progress

> *Maintained by `/prepare-issue` — durable record of where prep is; safe to resume from a fresh session.*

| Phase | State | Latest gate verdict |
|-------|-------|---------------------|
| 1 · Research          | ⬜ pending | — |
| 2 · Plan              | ⬜ pending | — |
| 3 · Plan review       | ⬜ pending | ready-check — · design-soundness — |
| 4 · Impl-plan         | ⬜ pending | — |
| 5 · Impl-plan review  | ⬜ pending | ready-check — · design-soundness — |
| 6 · Split             | ⬜ pending | — |

**Last updated:** 2026-07-20 11:19 · **Next:** Phase 1 · **Gate attempts:** P3 0/3 · P5 0/3
