# #197 — Nahrávky odpovedí z auta → automatické testy celej hlasovej cesty

**Triage:** enhancement · ready
**Založené:** 2026-10-10 (founder pri #196 — AI volania na priame Anthropic API: „mali by sme zbierať tie hlasové nahrávky, aj so zvukom auta… aby si aj ty mohol automatizovane testovať“; voľba: automaticky na náš server)

## Cieľ

Každá zmena rozpoznávania reči (STT), vyhodnocovania odpovedí alebo povelov sa dá automaticky overiť na **skutočných nahrávkach founderových odpovedí z auta**: nahrávka → STT → parser/grader → porovnanie s očakávaným výsledkom. Žiadne ručné exporty.

## Rozhodnutia foundera (2026-10-10)

- Nahrávky idú **automaticky na náš server**, len keď je zapnutý prepínač (len TestFlight/debug build, len founder).
- Pri nahrávkach, kde sa appka mýlila, founder len rýchlo potvrdí správny výsledok.

## Čo už existuje (#184 — prepis odpovedí po nahratí + detekcia ticha)

- iOS: Settings › voice diagnostics › „Save answer recordings“ (default OFF, len TF/debug) — surový 16 kHz WAV + sidecar JSON (jazyk, vstup/výstup, voice processing, conditioning, dĺžka, prepis), lokálne, export cez Súbory.
- `scripts/stt_compare.py` — WER porovnanie STT providerov nad exportovaným priečinkom.

## Tracky

- [ ] **197.1 — kontext k nahrávke (iOS):** sidecar doplniť o session/question id, typ otázky (MCQ/otvorená), čo appka rozhodla (verdikt, rozpoznaný povel), čas od začiatku otázky. Bez PII navyše (founder-only).
- [ ] **197.2 — upload (iOS + quiz-agent):** pri zapnutom prepínači po odoslaní odpovede upload WAV + sidecar na nový endpoint (autentifikovaný, len pre účty s diagnostikou / allowlist founder); server uloží do privátneho R2 bucketu (`voice-samples/…`) + riadok v DB (metadáta, `label` = null). Fail-soft: upload nikdy nespomalí ani nezablokuje hru.
- [ ] **197.3 — označovanie:** malá stránka (vzor: rating web) so zoznamom nahrávok, kde appka verdikt pravdepodobne pokazila (STT ≠ správna odpoveď, „zle“ pri vysokej podobnosti…); founder klikne správny výsledok / prepis. Ostatné sa berú ako správne podľa appky.
- [ ] **197.4 — replay testy:** skript (rozšírenie `stt_compare.py`) prehrá označené nahrávky celou cestou s aktuálnym kódom/modelmi → presnosť STT, verdiktu a povelov, chyby „správne označené ako zle“; výstup markdown do `docs/testing/runs/`. Spúšťať pri každej zmene STT/grader/parser modelu (#196 kroky 3–5).
- [ ] **197.5 — TF build na požiadanie foundera** → jazda s prepínačom ON → prvý replay report.
- [ ] **197.6 — detekcia ticha na dátach:** founder 2026-10-10: „príliš citlivá, nerozpozná, kedy som prestal hovoriť“. Sentry: 7/40 odpovedí na 15 s strope, hluk počítaný ako reč. (a) log zastavenia + čas začiatku/konca reči, (b) diagnostická nahrávka +3 s po zastavení, (c) replay detektora na nahrávkach + porovnanie alternatív (prahy, modelový VAD); zmena len s dátami. Rešerš: `docs/research/stt-eval-harness-2026-10-10.md`.

**Hotovo** = po jazde sú nahrávky na serveri bez ručného exportu, founder označil chybné prípady a replay skript vypíše tabuľku presnosti na nich.

Náklady: úložisko R2 zanedbateľné; replay beh = STT + Haiku 5.5 (~centy na desiatky nahrávok, Max kredit / ElevenLabs).
