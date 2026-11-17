# #237 — Povolenie povelov až na požiadanie + nový onboarding

**Triage:** enhancement · ready-for-agent
**Status:** 2026-11-17 plán; čaká výber variantov onboardingu (Design plátno)
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

## Úlohy

- **237.1 Varianty (dizajn).** 2–3 varianty onboardingu + pill s tlačidlom + výzva po kliknutiach na Design plátne. Gate: výber foundera.
- **237.2 Povolenie na požiadanie (logika).** Zrušiť žiadosť pri štarte. Služba povelov dostane explicitné „zapni povely“ (žiadosť → sťahovanie modelu → pripravené). Ak už povolené z minulosti, model sa pripraví ticho ako dnes. Stav „vypnuté, dá sa zapnúť“ odlíšený od „zamietnuté“ (vtedy tlačidlo vedie do Nastavení iOS).
- **237.3 Pill + výzva (UI).** Podľa vybraného variantu. Počítadlo klikov na hlasom ovládateľné tlačidlá, výzva max raz (a nie počas otázky, ktorá sa práve číta).
- **237.4 Onboarding (UI).** Podľa vybraného variantu; súhlas s AI ostáva na prvej strane (Apple 5.1.2(i)).
- **237.5 Kratší text systémového okna** (`InfoPlist.xcstrings`, en/sk/cs/uk), keďže ho hráč uvidí až po vlastnom kliknutí.

## Hotovo, keď

- Čerstvá inštalácia: žiadne systémové okno, kým hráč nič nezapne.
- Bez povolenia reči fungujú hlasové odpovede vrátane detekcie konca odpovede (overiť: ticho sa meria na mikrofóne, nie cez rozpoznávanie).
- Každá z ciest a/b/c vedie k funkčným povelom; zamietnutie ukáže cestu do Nastavení, nikdy slepý stav.
- Testy: každá cesta, zamietnutie, pomalé sťahovanie modelu (hráč vidí „pripravujem“, vie odísť), výzva sa nezobrazí druhýkrát; skutočné systémové volanie aspoň raz na simulátore alebo riadok v `docs/testing/system-calls-coverage.md`.
- Analytika: udalosť pre zapnutie povelov s cestou (onboarding / pill / výzva) a výsledkom.
