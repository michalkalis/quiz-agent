# #212.3 live run: two simulators + two bot guests (2026-10-28)

Local backend on branch `feat/212-ios-multiplayer` (throwaway DB with 184 en/sk questions), host on iPhone 18 Pro, guest on iPhone 17e (both iOS 27.0), bots "Jana" and "Peter" over the API. Ten questions, per-question reveal.

| Step | Result |
|------|--------|
| Together on Home (switch on) | pass, both phones |
| Host lobby, name asked once | pass |
| Guest joins by link, automatic name, rename reaches host | pass ("Quiet Fox" → "Zuzka") |
| 4 players in lobby | pass |
| Questions: countdown, Answered x/4, locked answer, reveal, guest waits | pass |
| Host auto-advance after reveal | **fail → fixed** (the auto-advance cancelled its own request; RoomViewModel+Host `moveOn`, test now covers it) |
| Leave app during a question | pass, host-only line "Zuzka: left Trubbo during 1 question" |
| Final ranking matches the server | pass (order and whole points; the speed bonus half point is not shown, by design the list shows correct answers) |

Late answers on Q2/Q4/Q7 were the driver's typing speed (~10 s per call on a ~30 s window), not an app fault. Nearby (same Wi-Fi) can't be checked locally: the local server sees non-global addresses.
