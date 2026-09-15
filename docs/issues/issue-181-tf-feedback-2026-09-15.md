# #181 — TF feedback 2026-09-15 (build 62, slovenský kvíz, otvorené otázky)

**Triage:** bug · done (agent-side) · **Owner:** agent · **Nadväzuje na:** #179 — TF feedback 2026-09-14

Founder testoval build 62 (2026-09-15 15:33–15:41, 2 screenshoty, 5 nálezov). Všetko opravené v jednej vetve `fix/181-tf-feedback-2026-09-15`.

## Nálezy a diagnóza

| # | Nález (founder) | Diagnóza | Oprava |
|---|-----------------|----------|--------|
| 1 | Toolbar položky sú zle (founder in-session: vzhľad kapsuly) | `QuizControlPill` kreslí vlastné pozadie `bgCard` + hairline nad systémovým sklom iOS 26; ✕ a ⋯ sú čisté systémové kapsuly → pilulka vyzerá ručne kreslená | Pozadie a rámik pilulky preč; kapsulu kreslí systém, ostáva len deliaca čiarka |
| 2 | Prázdny ružový box nad lištou (živý prepis) je zbytočný, potvrdzovacia obrazovka aj tak ukáže, čo som povedal | `QuestionVoiceFooter.transcriptCard` + `LiveTranscriptView` — na batch ceste a prvé sekundy streamu vždy prázdny | Karta + `LiveTranscriptView.swift` odstránené; jediný povrch nahrávania = lišta |
| 3 | Pri odpovedi nič nereagovalo, odpoveď sa objavila až po chvíli v potvrdení | Sentry log 13:37:38Z `STT fallback` = server bol práve v studenom štarte (viď 5); žiadosť o ElevenLabs token čakala plných 10 s s vypnutým mikrofónom, potom batch cesta bez živého prepisu → upload → prepis na serveri 13:37:49Z. Nie chyba rozpoznávania | Root cause = 5; navyše timeout tokenu 10 s → 5 s (`NetworkService.fetchElevenLabsToken`) |
| 4 | „Preskoč“ nemá hlásiť „Vyhodnocujem odpoveď“ — žiadna odpoveď nie je | `QuestionListenPhase.current` mapoval `.skipping` na `.evaluating` | Nový stav `.skipping` v `QuestionListenPhase` + `ListenBar.Mode`: „Preskakujem otázku“ / „Načítavam ďalšiu otázku“ (sk/cs/en), rovnaké sivé + spinner |
| 5 | Server spadol? Neprijímal odpovede, ani skip | Nespadol. Fly proxy pri `min_machines_running = 0` **uspal jediný stroj uprostred kvízu** (log 13:37:22Z „excess capacity, autostopping“ a znova ~13:39Z); studený štart ~18 s, medzitým `failed to connect to machine`; Sentry 13:40:00Z `submission stalled` + 4× `HTTP error` | Prod stroj: `fly machine update --autostop=off` (hotové 13:45Z); `fly.toml` `min_machines_running = 1` (platí od ďalšieho deployu) |

## Testy

- `QuestionListenBarTests`: `.skipping` mapovanie, žiadne povely, nezavrieteľné, render „Skipping the question“ + spinner, nikdy „Evaluating your answer“.
- `QuestionFooterInspectorTests` / `ScreenStateContractTests`: pri nahrávaní je len lišta, `question.liveTranscript` neexistuje.
- Cielené suity (listen bar, footer, screen-state, question view, skip, toolbar, streaming, view model): 177 testov zelených 2026-09-15. `swiftformat` na laptope nie je nainštalovaný — formátovanie neprebehlo (CI lint rozhodne).

## Náklady / infra

`min_machines_running = 1` = jeden `shared-cpu-1x` 512 MB stroj beží nonstop (~3 USD/mes. namiesto ~0 pri uspávaní). Alternatíva `auto_stop_machines = "suspend"` (obnova < 1 s) zamietnutá zatiaľ ako menej overená s volume; prehodnotiť pri väčšom počte strojov.

## Stav

- 2026-09-15: založené, diagnóza + opravy v jednej session; prod stroj už nezaspáva (machine flag). Open: založiť PR, review, merge, `fly deploy` (klasifikátor deploy z agenta blokol → founder alebo ďalšia session), TF build na požiadanie.
