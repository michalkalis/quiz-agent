# Same-room multiplayer ("Hra spolu") — research, 2026-10-23

Design canvas with all screen proposals + this research in Slovak: https://claude.ai/artifact/9FH1tX3o5TRtBnnyFzcUV7
Status: founder decided 2026-10-28 (several recommendations below overturned: no App Clip, not MCQ-only, same-Wi-Fi discovery wanted) → plan [issue-212](../issues/issue-212-multiplayer-same-room.md).

## Founder brief (2026-10-23)
One phone hosts, others join with their own phones; host answers too; answers revealed to everyone after each question/round; final scoreboard for all. Joining must be as automatic as possible (no typed codes). Offline not required (app needs internet anyway). Consider: button next to Start, tab bar, monetization, voice on guest phones.

## Comparable apps
| App | Join | Who pays | Note |
|---|---|---|---|
| [Kahoot](https://support.kahoot.com/hc/articles/360039890713) | PIN / link / QR, nickname only | host; players always free | speed scoring is top complaint → "Accuracy" mode ([scoring](https://support.kahoot.com/hc/articles/115002303908)) |
| [Jackbox](https://www.jackboxgames.com/how-to-play) | 4-letter code on jackbox.tv, later QR | host only | phones are controllers |
| [Netflix Game Night](https://help.netflix.com/en/node/602905750076006) | QR from TV | free, no login on phone | separate controller app on iPhone |
| [Ooh, I Know!](https://apps.apple.com/app/id1393888298) | QR → App Clip, or 4-digit code | 4 players free, 8 for $4.99 | closest comp (music trivia) |
| [Signal Fire Party](https://apps.apple.com/app/id6760261815) | local Bluetooth lobby | $9.99 trivia IAP | offline |
| [Spaceteam](https://spaceteam.ca/faq) | manual pick Wi-Fi/BT/Internet | free | anti-pattern: too many steps |

## Joining options (iOS)
- **QR + Universal Link (recommended):** works on Wi-Fi and cellular since the session is in the cloud; only camera needed. Gap: app-missing case loses join context after App Store install ([Apple forum](https://developer.apple.com/forums/thread/772811)) → App Clip.
- **App Clip for guests without the app:** tap-only MCQ client fits; physical invocation limit 15 MB ([forum](https://developer.apple.com/forums/thread/740061)); unconfirmed iOS 26 "App Clip Unavailable" reports — verify on device.
- **ShareLink / AirDrop / messages:** remote guests (second car).
- **SharePlay over AirDrop (iOS 17+), later:** "bring phones together" prompt; app must be installed; no reliability data ([WWDC23](https://developer.apple.com/videos/play/wwdc2023/10239/)).
- **Rejected for v1:** MultipeerConnectivity/Bonjour (local-network prompt, silent denial, no state API — [forum](https://developer.apple.com/forums/thread/774244)); Nearby Interaction (UWB, not a join mechanism); Game Center nearby (needs GC login).
- iOS no longer exposes the device name → auto-assigned fun name + colour, editable with one tap.

## Voice on guest phones: no
Mics hear each other and the host's TTS; a spoken answer leaks to the room. No comparable app does per-phone voice in one room. Host phone reads the question aloud (existing TTS); host may answer by voice (driver), guests tap MCQ.

## Gameplay rules proposed
- MCQ only in multiplayer (deterministic, simultaneous, no LLM). Corpus is ~20–30 % MCQ today → need distractors for open questions before launch.
- 1 point per correct answer, no speed points (kids, driver); speed only breaks ties; no answer by deadline = 0.
- Reveal when last player answers or timer ends; show who answered what + "Vedeli X z N".
- Late joiner starts next question at 0; reconnect resumes the game.

## Monetization variants
- **M1 host pays (recommended):** each question counts once against host quota regardless of player count; guests free, no account. No new product.
- **M2 party in Plus:** free room ≤ 4, Plus up to 8 and party games don't consume questions. Risk: 5th player hits a wall mid-party.
- **M3 party ticket:** 24 h consumable; third store product, price TBD.
- Marginal cost ≈ solo game (one question fetch + one TTS; MCQ graded on device/server without LLM).
- Growth: guests are the acquisition funnel (Kahoot cites player→account loop, [source](https://kahoot.com/blog/2021/02/10/an-update-from-ceo-eilert-hanoa-kahoot-reports-q4-2020-results-delivering-a-year-of-record-high-growth/)); idea: bonus questions for a guest who installs.

## Navigation
No tab bar now (consistent with 2026-10-08 founder note). Entry = "SPOLU" icon button beside Štart (same pattern as Ďalej + ZOSTAŇ). Tab bar only once 3+ equal top-level areas exist.

## Codebase readiness (2026-10-23)
- `Participant` model + `QuizSession.mode/room_code/participants` exist (`packages/shared/quiz_shared/models/session.py`), dormant.
- Participant add/remove endpoints are owner-only (#144 — session route authorization); no join-by-code, no WebSocket/SSE (clients would poll).
- Quota is per subject (`apps/quiz-agent/app/usage/tracker.py`) → M1 works without changes.
- Proposed phasing: (1) cloud session + QR/link join with the full app, (2) App Clip guest client, (3) SharePlay nearby shortcut.
