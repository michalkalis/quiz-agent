# CarPlay entitlement request — #97 — CarPlay support

Phase 1 of `docs/issues/issue-97-carplay-support.md`.

**Filed 2026-10-15** (agent via Playwright, founder signed in) at developer.apple.com/contact/request/carplay/ as missinghue s.r.o. (KAGWHPZZFQ), contact hello@missinghue.com. The form asked only for the app type (**Voice-Based Conversational**) and acceptance of the CarPlay Entitlement Addendum (Rev. 06-08-2026); Apple replied on screen "We'll review your request and contact you soon". The description below is for Apple's follow-up e-mail, which usually asks for app details.

## Facts for Apple's follow-up

| Field | Value |
|---|---|
| Team | missinghue (KAGWHPZZFQ) |
| App name | Trubbo |
| Bundle ID | `com.missinghue.hangs` |
| Category | **Voice-based conversational** (`com.apple.developer.carplay-voice-based-conversation`, iOS 26.4+) — the only category whose apps may record voice in CarPlay (CarPlay Developer Guide, October 2026, "Audio handling → Recording") |
| Platforms / languages | iPhone; English, Slovak, Czech |
| Status | Public TestFlight beta; version 1.1 in App Store review |

## Description (paste into the form)

Trubbo is a voice-first quiz host for the car. The driver starts a round with one tap; from then on the whole interaction is spoken. Trubbo reads a question aloud, listens for the spoken answer, says whether it was right, adds one short sentence of background, and moves on. The driver can also just say "repeat", "skip" or "stop". No reading, typing or tapping is needed while driving.

In CarPlay, Trubbo would use the Voice Control template as its main screen, showing only the conversation state (speaking, listening, thinking) and two buttons (pause, end round). A list template would let the driver pick a topic or question pack before starting, within the 3-template limit. Answers are never shown as text on the car screen: questions, answers and explanations are spoken only, as the guidelines for voice-based conversational apps require.

The audio session is active only while a round is running and is released when the round ends or is paused, so the car's radio or music resumes. Trubbo does not use a wake word, does not control the car or the phone, and does not show notifications in CarPlay.

Why CarPlay: Trubbo is already used on long drives today through the phone mount and car speakers. A native CarPlay surface lets drivers start, pause and end a round from the car screen instead of reaching for the phone, which is the safer way to use an app that is built to be heard, not looked at.

## Notes for the founder (not for the form)

- Apple describes the category as "conversations with voice assistants" and excludes games platform-wide. The text above is truthful but leads with the spoken-conversation shape, not the word "game". Rejection is still a real outcome; nothing in our plan waits for the answer.
- Apple gives no review deadline (days to months, silence is common). Record the filing date and every reply in the issue file.
