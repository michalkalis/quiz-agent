# #237 — Povolenie povelov až na požiadanie + nový onboarding

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-17 PAUZA; varianty vybrané ([plátno](https://claude.ai/artifact/LiGtJvPVQHWq31xfYEqL2e)); 237.2–237.5 naprogramované v WIP commite na vetve `feat/237-commands-on-request` (worktree `.claude/worktrees/issue-237`), appka aj testy sa skompilujú, 82/82 cielených testov prešlo
**Founder:** 2026-11-17 „appka pri prvom spustení hneď žiada speech recognition oprávnenia, to je veľmi zlé UX a nie je jasné, k čomu slúži. Aj celý onboarding je len taký z povinnosti… netreba forcovať ten systémový alert za každú cenu.“

## Prečo

Pri prvom spustení appka hneď (ešte pred onboardingom) vyskočí systémové okno na rozpoznávanie reči. Hráč nevie, načo je, text je dlhý a anglický. Rozpoznávanie reči treba len na hlasové povely („štart“, „ďalej“…); odpovede hlasom (mikrofón + server) a tlačidlá fungujú bez neho.

Stav v kóde:
- `AppState.swift:204,212` pri štarte appky volá žiadosť o rozpoznávanie reči + sťahovanie jazykového modelu.
- Onboarding (`OnboardingView.swift`): Vitaj („ANSWER BY VOICE“ + súhlas s AI) → Povely (3 riadky) → Mikrofón. Informačne chudobný.
- Mikrofón: onboarding, inak systémové okno pri prvom kvíze (`QuizViewModel.swift:1336`). **Founder: nechať ako je.**
- Iné povolenia appka nežiada (notifikácie, sledovanie, poloha nie).

## Rozhodnutia foundera (2026-11-17)

1. Rozpoznávanie reči sa pýta **len keď hráč chce**, tromi cestami (všetky):
   - a) onboarding: zrozumiteľné vysvetlenie + tlačidlo „Zapnúť povely“, dá sa preskočiť;
   - b) panel povelov (zelený pill): tlačidlo vpravo „Zapnúť povely“, kým nie sú zapnuté;
   - c) po ~3 klikoch na tlačidlá, ktoré sa dajú ovládať aj hlasom: vlastná krátka výzva („Toto vieš aj povedať“), systémové okno až po súhlase; jednorazovo.
2. Mikrofón ostáva ako dnes.
3. Onboarding prerobiť obsahovo: najprv varianty na Design plátne, founder vyberie, potom kód.

## Výber foundera z plátna (2026-11-17)

- Onboarding **A bez A1 a A2**: len Mikrofón → Hlasové príkazy. Súhlas s AI službami (Apple 5.1.2(i)) sa presúva na stránku Mikrofón. „Možno neskôr“ pri mikrofóne onboarding končí (príkazy bez mikrofónu nejdú).
- Lišta príkazov **1** (tlačidlo vpravo): vypnuté → „Zapni“, pripravuje sa, zapnuté, zamietnuté → „Nastavenia“. Na obrazovke otázky v stavoch, keď by sa ukazovali slová príkazov.
- **Výzva po 3 ťuknutiach sa nerobí** (cesta c padá): lišta s tlačidlom je stále na očiach. Kto lištu nechce, vypne ju v Nastaveniach („Command hints“, už existuje).
- Slovo **„príkazy“**, nie „povely“ (tak ich appka volá všade).

## Úlohy

- **237.1 Varianty (dizajn).** 2–3 varianty onboardingu + pill s tlačidlom + výzva po kliknutiach na Design plátne. Gate: výber foundera.
- **237.2 Povolenie na požiadanie (logika).** Zrušiť žiadosť pri štarte. Služba povelov dostane explicitné „zapni povely“ (žiadosť → sťahovanie modelu → pripravené). Ak už povolené z minulosti, model sa pripraví ticho ako dnes. Stav „vypnuté, dá sa zapnúť“ odlíšený od „zamietnuté“ (vtedy tlačidlo vedie do Nastavení iOS).
- **237.3 Lišta s tlačidlom (UI).** Podľa varianty L1; skryje ju prepínač „Command hints“ aj hlavný prepínač príkazov; pri zamietnutom mikrofóne sa tlačidlo neukáže.
- **237.4 Onboarding (UI).** Podľa vybraného variantu; súhlas s AI ostáva na prvej strane (Apple 5.1.2(i)).
- **237.5 Kratší text systémového okna** (`InfoPlist.xcstrings`, en/sk/cs; uk až s #231 ukrajinčina), keďže ho hráč uvidí až po vlastnom kliknutí.

## Hotovo, keď

- Čerstvá inštalácia: žiadne systémové okno, kým hráč nič nezapne.
- Bez povolenia reči fungujú hlasové odpovede vrátane detekcie konca odpovede (overiť v 237.2: ticho sa meria na úrovni mikrofónu, zlyhaný štart rozpoznávania dnes vypína len príkazy, ale zvuk odpovede môže ísť cez ten istý zvukový reťazec).
- Každá z ciest a/b vedie k funkčným povelom; zamietnutie ukáže cestu do Nastavení, nikdy slepý stav.
- Testy: každá cesta, zamietnutie, pomalé sťahovanie modelu (hráč vidí „pripravujem“, kvíz ide ďalej); skutočné systémové volanie aspoň raz na simulátore alebo riadok v `docs/testing/system-calls-coverage.md`.
- Analytika: udalosť pre zapnutie povelov s cestou (onboarding / lišta) a výsledkom.

## Pokračovanie po pauze (2026-11-17)

Hotové vo WIP: žiadna výzva pri štarte ani pri zmene jazyka; lišta „Zapni“ / „Pripravujem príkazy…“ / „Nastavenia“; onboarding Mikrofón → Hlasové príkazy (súhlas s AI na stránke Mikrofón); kratší text okna en/sk/cs; udalosť `voice_commands_turned_on` (appka + povolené na serveri); bez povolenia beží poslucháč len pre odpovede (koniec reči funguje).

Ostáva:
1. Spustiť zvyšné testy: snapshoty (komponenty, obrazovky, hero), celé AnalyticsEventsTests a SilenceDetectionServiceTests; 4 preskočené serverové testy v `test_analytics_events.py` overiť.
2. `xcstringstool sync`, doplniť sk/cs nových textov (poznámky na lište, diagnostika v Nastaveniach).
3. Nahrať snapshoty: 5 nových stavov lišty, onboarding mikrofón/príkazy/zamietnuté, zmazať staré welcome/features; PNG pozrieť pred commitom.
4. Lint: a11y id, jazyk rozhrania, design tokeny.
5. Zlúčiť WIP do riadneho commitu, PR, review, merge.

Na vedomie foundrovi: ťuknutie na „Zapni“ počas kvízu kvíz pozastaví, kým je otvorené okno iOS; hodnoty `onboarding_finished` sú teraz mic_later, mic_denied, commands_on, commands_later.
