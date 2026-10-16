# #207 — Pripravenosť na produkciu so skutočnými používateľmi

**Triage:** chore · in-progress
**Založené:** 2026-10-16 (founder: „ako moc sme nachystaný na beh na produkcii s reálnymi užívateľmi — migrácie, verzovanie, výpadky, provideri, bezpečnosť, náklady, kredity“)
**Zdroj:** 3 read-only audity nad `origin/main` de6df64a + živý stav prodov 2026-10-16 (prevádzka/infra, náklady/kredity, bezpečnosť/súkromie/iOS release). Nadväzuje na [#193 — spevnenie pred betou](issue-193-beta-hardening.md); čo je tam hotové, sa tu neopakuje.

## Rozhodnutia foundera (2026-10-16)

- OpenRouter kredit dobitý (bol na nule; prod `LLM_GATEWAY=openrouter` → záložný hodnotiteľ odpovedí bol mŕtvy).
- Anthropic auto-reload pred koncom promo kreditu (11-06) — **vyriešime neskôr**, nepripomínať každú session.
- ElevenLabs Starter (30k kreditov, nedá sa dokúpiť) — **ostáva, beta ukáže** skutočnú spotrebu.
- **Vlastné balíčky: primárne Fly worker cez Anthropic API (mesačný Max kredit), `mba` session worker len ako záloha** — opak dnešného stavu.
- **Git:** starý dizajn (1.0) ostane v gite, redizajn je odteraz produkčná verzia; správu gitu necháva na agentovi (zjednodušený flow vhodný pre agentov).
- **Monitoring bez novej služby** — postaviť na tom, čo už máme (Sentry, Fly, GitHub, mba), prípadne cloud routine cez Claude.
- Body „krátko po spustení“ aj „neskôr“ z auditu riešiť **teraz**; poradie určuje agent; práca beží na `mba`, sessions si spravuje agent sám.

## Stav auditu (zhrnutie)

- **OK:** App Attest + tokeny + admin kľúče + webhook RevenueCat, Plus overovaný na serveri, žiadne tajomstvá v appke; mazanie účtu úplné; vynútená aktualizácia + vypínač objednávok + oznam; nočná šifrovaná záloha mimo Fly s overenou obnovou; migrácie len pridávajú a pri chybe zastavia deploy; záložný hlas / preklad / timeouty AI; dSYMy v Sentry.
- **Najväčšie riziká:** výpadok zistíme až po hodinách (plánovaný 30-min monitor GitHub reálne spúšťa ~raz za 4 h, len e-mail); balíčky stoja na `mba`; všetko na 1 stroji v 1 regióne, DB bez repliky a s RPO až 24 h; deploy z laptopu bez vynútených testov; 1.1 nemá opravnú vetvu; privacy štítky v ASC nesedia.

## Poradie prác

P0 = pred/ihneď po vydaní 1.1 · P1 = do pár dní · P2 = hneď potom. Každý bod = malá samostatná PR.

### A. Git a vydávanie (P0)

- [ ] 207.1 Trunk-based flow: `main` = produkcia (redizajn), krátke vetvy + PR, nedokončené veci za prepínačmi. Tagy `ios/1.0-final` (hlava `release/1.0`, starý dizajn) a `ios/1.1-b76` (f0f5c5eb, build odoslaný do review 10-14). Opravná vetva `hotfix/<verzia>` sa zakladá z tagu len keď treba, oprava sa cherry-pickne do `main`. `release/1.0` zmraziť ako archív; pravidlá v `.claude/rules/shared.md` + TestFlight skill.
- [ ] 207.2 `ios-release.yml` po úspešnom uploade sám pushne tag `ios/<verzia>-b<build>` (každý build dohľadateľný bez ručnej práce).
- [ ] 207.3 Phased release pre 1.1 v App Store Connect — overiť/zapnúť cez ASC API.

### B. Vlastné balíčky: Fly worker primárne, mba záloha (P0)

- [ ] 207.4 Fly `worker` na predvolenej fronte s Claude cez priame Anthropic API (Max kredit, rezerva podľa `credit_gate`); `ORDER_QUEUE_NAME` späť na predvolenú.
- [ ] 207.5 `mba` session worker ako záloha: preberá objednávky, len keď Fly worker nedáva heartbeat / objednávka visí > N min (bez dvojitej generácie — existujúce zámky z PR #275). Deploy `quiz-pack-api` už nesmie omylom spúšťať/zastavovať zlý worker.
- [ ] 207.6 Kontrola objednávok po obnove zo zálohy: admin príkaz porovná App Store transakcie (App Store Server API) s objednávkami v DB a dorobí chýbajúce.

### C. Zachytenie výpadkov bez novej služby (P0)

- [ ] 207.7 Minútová kontrola z existujúcich nástrojov: Sentry Uptime monitor na oba `/health` (overiť, či náš Sentry plán má uptime monitory) + `mba` launchd watchdog každú minútu ako druhý pozorovateľ; upozornenie do telefónu cez Sentry (e-mail/push). Ak Sentry uptime nie je v pláne → Sentry Cron monitor (heartbeat posiela samotná služba) + mba watchdog.
- [ ] 207.8 Upozornenia Sentry na chybovosť a latenciu (pravidlá ako kód cez Sentry API), worker heartbeat ako Sentry Cron; zlyhanie samotnej kontroly kreditov tiež alarmuje (dnes len log).
- [ ] 207.9 Stav DB: zaplnenie disku, spojenia, pamäť → denne + alarm pri ≥ 70 %; zväčšiť volume `quiz-pack-db` (1 GB) s rezervou.
- [ ] 207.10 Logy dlhšie ako Fly ring buffer: štruktúrované chyby do Sentry Logs (už platíme) namiesto novej log služby.

### D. Peniaze a zneužitie (P1)

- [ ] 207.11 Záložný hodnotiteľ odpovedí na priame OpenAI (nie cez OpenRouter), aby jeden prázdny kredit nezhodil obe cesty.
- [ ] 207.12 Denné kontroly kreditov aj pre Anthropic (Admin API cost report vs. promo/kúpený zostatok) a OpenAI (usage API); Fly faktúra — mesačný odhad z Fly API.
- [ ] 207.13 Limity na používateľa: realtime STT tokeny/deň, dĺžka nahrávky v sekundách, počet pokusov na otázku/deň; rate limit `/entitlements/sync`; globálny denný strop ElevenLabs → automatický prechod na záložný hlas.
- [ ] 207.14 Meranie skutočnej ceny otázky (LLM + STT + TTS) z analytiky → podklad pre founder rozhodnutie o limite Plus (dnes odhad ~6 $ pri 1 000 otázkach vs. ~4,6 $ čistý príjem). Rozhodnutie o cene/limite = founder.

### E. Nasadzovanie a prostredia (P1)

- [ ] 207.15 Backend CI ako povinná kontrola v rulesete (vedľa `claude-review`).
- [ ] 207.16 Deploy cez GitHub Actions po merge do `main`: staging → smoke test → prod → smoke test; pri zlyhaní stop + Sentry/e-mail. `/deploy` skill ostáva ako ručná núdzová cesta.
- [ ] 207.17 Staging so samostatnými kľúčmi providerov s nízkymi limitmi (staging nesmie míňať prod kredit) a vlastnou DB inštanciou alebo aspoň oddelenými rolami (dnes zdieľa prod cluster).
- [ ] 207.18 Prepínače (min. verzia, objednávky, oznam) bez reštartu stroja: hodnoty z DB s admin endpointom namiesto Fly secrets.

### F. Odolnosť a dáta (P1)

- [ ] 207.19 Návrh (pred implementáciou `/design-soundness`): quiz-agent bez volume (TTS cache → R2, `ratings.db` → Postgres) → 2 stroje a rolling deploy bez výpadku; Postgres WAL archív (point-in-time obnova) do R2 alebo replika; Redis perzistencia. Rešpektovať: Fly Managed Postgres nie, Hetzner preferovaný hosting do budúcna.
- [ ] 207.20 Implementácia podľa schváleného návrhu 207.19 (po krokoch, každý s overenou obnovou).

### G. Súkromie a GDPR (P1)

- [ ] 207.21 Privacy štítky: pregenerovať `fastlane/app_privacy_details.json` z `PrivacyInfo.xcprivacy` a skutočných dát (bez mena/e-mailu; ID zariadenia, fotky z feedbacku, analytika, diagnostika), porovnať s ASC a nahrať.
- [ ] 207.22 Zásady ochrany súkromia sk/cs/en: zoznam spracovateľov, prenos mimo EÚ (štandardné zmluvné doložky / adekvátnosť), doba uchovávania. Zoznam DPA so spracovateľmi + odkazy (podpis/akceptácia = founder krok).
- [ ] 207.23 Sentry backend `before_send`: odfiltrovať texty odpovedí a telá požiadaviek; TF build neposiela text hlasových povelov bez zmienky v zásadách.

### H. Hygiena a kompatibilita (P2)

- [ ] 207.24 Docker: inštalácia z `uv.lock` (nie ručný zoznam), base image pinnutý na digest, beh ako non-root; pinnuté verzie GitHub actions.
- [ ] 207.25 Dependabot (security updates + mesačné verzie) pre Python, Swift balíčky a actions.
- [ ] 207.26 CI kontrola kompatibility API: OpenAPI diff voči poslednému vydanému tagu `ios/*`; zlyhá pri odobratom poli/endpointe.
- [ ] 207.27 Jeden runbook výpadku `docs/setup/incident-runbook.md`: ako zistiť, kto čo robí, vypínače, rollback, obnova DB, oznam používateľom.

## Founder kroky

- Sprístupniť `mba` pre Remote Control (návod v session 2026-10-16), aby agent spúšťal sessions sám.
- 207.22: akceptovať DPA u spracovateľov, kde to vyžaduje klik v ich konzole (zoznam pripraví agent).
- Neskôr: Anthropic auto-reload so stropom pred 11-06.
