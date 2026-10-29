# #215 — Prví kvalitní testeri mimo rodiny

**Triage:** enhancement · ready-for-agent
**Status:** 2026-10-29 founder: prvá vlna len ~5 testerov (mix), WhatsApp skupina, každú správu vidí pred odoslaním, oslovovanie a prehľad vedie agent; zľava pre zakladajúcich až podľa toho, ako sa testeri zapoja.
**Súvisí:** #210 — marketing na sociálnych sieťach · [research](../research/superfan-testers-2026-10-28.md) · tok buildov: [release-flow](../setup/release-flow.md)

## Cieľ

Nájsť ~5 ľudí, ktorí kvízy už teraz pravidelne hrajú s inými ľuďmi a Trubbo by naozaj používali. Rodina a kamaráti appku nepotrebujú, takže ich spätná väzba je slabá (zo 4 pozvaných zatiaľ nikto ani neprijal pozvánku).

Hotovo, keď:
- 5 testerov má appku nainštalovanú z Public bety,
- po 3 týždňoch aspoň 3 z nich hrajú aspoň 2× týždenne,
- máme aspoň 10 konkrétnych pripomienok (čo nebavilo, kde sa zasekli, čo by chceli),
- máme odpoveď na otázku „Ako by si sa cítil, keby Trubbo zmizlo?“ a podľa nej rozhodnutie o zľave.

## Koho hľadáme

Rozhoduje správanie, nie sľuby (rešerš: Superhuman, The Mom Test). Dobrý tester:
- za posledný mesiac hral kvíz s ľuďmi (hospodský kvíz, chata, auto, párty, s deťmi),
- má iPhone s iOS 26 alebo novším,
- súhlasí s 2 hrami týždenne a s krátkou odpoveďou v skupine raz týždenne.

Kto chce len appku zadarmo, na tieto otázky odpovie vágne alebo vôbec. Zodpovedanie 4 otázok je malý záväzok a už samo o sebe filtruje.

## Dve rôzne role

| Rola | Kto | Prečo | Váha spätnej väzby |
|------|-----|-------|------|
| **Testeri hráči** (tých 5) | pravidelní hráči hospodských kvízov, rodiny na cestách, partie na chatách | bežní hráči Trubbo; ich správanie ukáže, či appka chytí | hlavná: čo robia (hry/týždeň), potom čo hovoria |
| **Poradcovia k otázkam** (1–2, mimo tých 5) | organizátori a moderátori kvízov (Hospodský kvíz, Chytrý kvíz) | otázky píšu každý týždeň a vedia, čo pri stole baví a čo je príliš ťažké | len k otázkam, nie k tomu, či appka baví |

Organizátori nie sú bežní hráči: chcú ťažké a overené otázky. Preto ich chuť nepreberáme ako meradlo zábavy (rešerš Q4), ale ich pohľad na kvalitu otázok dopĺňa našu rubriku. Druhý prínos: poznajú svojich pravidelných hráčov a môžu nás k nim nasmerovať. Pozor: Trubbo môžu vnímať ako konkurenciu, preto ho predstavujeme ako hru na doma a na cesty, nie ako náhradu ich večerov.

## Kanály prvej vlny (mix)

1. **E-mail organizátorom** (agent z hello@missinghue.com): Hospodský kvíz, Chytrý kvíz / Pubquiz Brno, ESN Bratislava (Erasmus kvízy), IT pub kvíz Košice. Prosba o 1–2 tipy na pravidelných hráčov a ponuka pozrieť si otázky.
2. **1–2 FB skupiny** (príspevok pošle founder, agent Facebook neovláda): stolové hry alebo cestovanie s deťmi / chata. Najprv správa adminovi, až potom príspevok.
3. Anglické komunity (r/PubQuiz, r/quiz) až v ďalšej vlne.

## Ako testerov pridáme

- Pozvánka **e-mailom do skupiny Public beta** (`/add-tester`), nie verejným odkazom. Ľudí z verejného odkazu nepoznáme podľa mena, pri e-mailovej pozvánke vidíme pri každom testerovi inštaláciu, počet hier a pády.
- Do Public bety ide build len na founderov povel a po Beta App Review od Apple (deň–dva).
- Nákupy v TestFlighte sú testovacie, takže testeri majú Plus počas bety zadarmo bez ďalšieho nastavovania.

## Komunikácia

- **WhatsApp skupina „Trubbo testeri“** založí a vedie ju founder z telefónu. Agent WhatsApp nevidí, preto mu founder raz týždenne pošle export chatu (WhatsApp: Export chat, bez médií) a agent z neho spraví súhrn.
- Všetky správy (e-maily, FB príspevok, uvítanie v skupine, týždenné otázky) agent pripraví po slovensky alebo česky, founder ich vidí v artefakte a schváli **pred** odoslaním.
- Odpovede na e-maily číta agent z hello@ a vedie prehľad v tomto pláne (tabuľka nižšie, bez e-mailov, repo je verejné).

## Kroky

- [ ] **215.1** Agent: texty (e-mail organizátorom cs/sk, FB príspevok a správa adminovi, 4 výberové otázky, uvítanie v skupine, týždenná otázka) + zoznam kontaktov → artefakt na schválenie.
- [ ] **215.2** Founder: schváli alebo upraví texty, založí WhatsApp skupinu, vyberie 1–2 FB skupiny.
- [ ] **215.3** Agent pošle schválené e-maily, founder pošle FB príspevok. Odpovede zbiera agent.
- [ ] **215.4** Agent navrhne 5 testerov podľa odpovedí, founder potvrdí. Pozvánky cez `/add-tester` do Public bety, founder dá povel na build do bety.
- [ ] **215.5** 3 týždne: raz týždenne súhrn (údaje z TestFlightu na testera, spätná väzba z TestFlightu a hello@, export WhatsAppu) → zoznam pripomienok do backlogu.
- [ ] **215.6** Po 3 týždňoch otázka „Ako by si sa cítil, keby Trubbo zmizlo?“ (veľmi / trochu / vôbec by mi nechýbalo). Founder rozhodne: zľava pre zakladajúcich po spustení v App Store (napr. cez Apple kódy s ponukou), alebo bez zľavy. Ďalšia vlna áno/nie a aká veľká.

## Prehľad oslovení

| Kontakt | Rola | Oslovené | Odpoveď | Stav |
|---------|------|----------|---------|------|
| — | — | — | — | — |

## Mimo rozsahu

- Platení testeri alebo burzy testerov (BetaList, BetaFamily): ľudia odtiaľ sú väčšinou iní vývojári alebo zberatelia vecí zadarmo, kvalitu nikto neporovnával (rešerš Q5).
- Verejný odkaz na Public betu na sociálnych sieťach: príde veľa ľudí, ale nevieme, kto sú.
- Zmeny v appke kvôli testerom (napr. kód testera): pri 5 ľuďoch s e-mailovou pozvánkou netreba.
