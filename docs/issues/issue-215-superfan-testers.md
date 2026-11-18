# #215 — Prví kvalitní testeri mimo rodiny

**Triage:** enhancement · ready-for-agent
**Status:** 2026-10-29 founder: prvá vlna len ~5 testerov (mix), každú správu vidí pred odoslaním, oslovovanie a prehľad vedie agent; zľava pre zakladajúcich až podľa toho, ako sa testeri zapoja. Po revízii textov: bez WhatsApp skupiny (founder píše s každým zvlášť), menej formálne, od organizátora pýtame 1–2 hráčov, testovanie na pár týždňov (ak sú obe strany spokojné, aj dlhodobo), 3 obrázky z appky v e-mailoch aj na FB. Texty neopisujú Trubbo ako „moderuje sám“, ale ako kvíz, ktorý sa hrá hlasom a netreba pri ňom ťukať ani čítať.
**Súvisí:** #210 — marketing na sociálnych sieťach · [research](../research/superfan-testers-2026-10-28.md) · tok buildov: [release-flow](../setup/release-flow.md)

## Cieľ

Nájsť ~5 ľudí, ktorí kvízy už teraz pravidelne hrajú s inými ľuďmi a Trubbo by naozaj používali. Rodina a kamaráti appku nepotrebujú, takže ich spätná väzba je slabá (zo 4 pozvaných zatiaľ nikto ani neprijal pozvánku).

Hotovo, keď:
- 5 testerov má appku nainštalovanú z Public bety,
- po 3 týždňoch aspoň 3 z nich ešte stále pravidelne hrajú,
- máme aspoň 10 konkrétnych pripomienok (čo nebavilo, kde sa zasekli, čo by chceli),
- máme odpoveď na otázku „Ako by si sa cítil, keby Trubbo zmizlo?“ a podľa nej rozhodnutie o zľave.

## Koho hľadáme

Rozhoduje správanie, nie sľuby (rešerš: Superhuman, The Mom Test). Dobrý tester:
- kvízy hráva, napríklad hospodský kvíz, na chate, v aute, na párty alebo s deťmi,
- má iPhone s iOS 26 alebo novším,
- občas napíše, ako sa hralo.

Požiadavky sú v príspevku ako zoznam, nie ako otázky. Uchádzač napíše len pár slov o tom, kedy a s kým kvízy hráva. Kto chce len appku zadarmo, napíše vágne alebo vôbec, takže aj taká krátka správa filtruje.

## Dve rôzne role

| Rola | Kto | Prečo | Váha spätnej väzby |
|------|-----|-------|------|
| **Testeri hráči** (tých 5) | pravidelní hráči hospodských kvízov, rodiny na cestách, partie na chatách | bežní hráči Trubbo; ich správanie ukáže, či appka chytí | hlavná: čo robia (hry/týždeň), potom čo hovoria |
| **Poradcovia k otázkam** (1–2, mimo tých 5) | organizátori a moderátori kvízov (Hospodský kvíz, Chytrý kvíz) | otázky píšu každý týždeň a vedia, čo pri stole baví a čo je príliš ťažké | len k otázkam, nie k tomu, či appka baví |

Organizátori nie sú bežní hráči: chcú ťažké a overené otázky. Preto ich chuť nepreberáme ako meradlo zábavy (rešerš Q4), ale ich pohľad na kvalitu otázok dopĺňa našu rubriku. Druhý prínos: poznajú svojich pravidelných hráčov a môžu nás k nim nasmerovať. Pozor: Trubbo môžu vnímať ako konkurenciu, preto ho predstavujeme ako hru na doma a na cesty, nie ako náhradu ich večerov.

## Kanály prvej vlny (mix)

1. **E-mail organizátorom** (agent z hi@trubbo.app): Hospodský kvíz (e-mail), Chytrý kvíz (formulár na webe), Košice IT Valley / IT Pub Quiz (e-mail). PubQuiz.cz (len telefón) a ESN Bratislava (bez kontaktu, posledný kvíz 2023) vynechané. Aktívneho slovenského organizátora so zverejneným kontaktom okrem Košíc sme nenašli, Slovákov hľadáme hlavne cez FB. Prosba o 1–2 tipy na pravidelných hráčov a ponuka pozrieť si otázky.
2. **1–2 FB skupiny** (príspevok pošle founder, agent Facebook neovláda): stolové hry alebo cestovanie s deťmi / chata. Najprv správa adminovi, až potom príspevok.
3. Anglické komunity (r/PubQuiz, r/quiz) až v ďalšej vlne.

## Ako testerov pridáme

- Pozvánka **e-mailom do skupiny Public beta** (`/add-tester`), nie verejným odkazom. Ľudí z verejného odkazu nepoznáme podľa mena, pri e-mailovej pozvánke vidíme pri každom testerovi inštaláciu, počet hier a pády.
- Do Public bety ide build len na founderov povel a po Beta App Review od Apple (deň–dva).
- Nákupy v TestFlighte sú testovacie, takže testeri majú Plus počas bety zadarmo bez ďalšieho nastavovania.

## Komunikácia

- **Founder píše s každým testerom zvlášť**, cez WhatsApp alebo cez e-mail, podľa toho, čo testerovi vyhovuje. Spoločnú skupinu nezakladáme, väčšina ľudí nechce písať s cudzími. Agent WhatsApp nevidí: founder mu občas pošle export rozhovoru alebo len napíše, čo zaznelo. Z testerov nič nevynucujeme, žiadne povinné hry ani týždenné otázky.
- Všetky správy (e-maily, FB príspevok, uvítanie v skupine, týždenné otázky) agent pripraví po slovensky alebo česky, founder ich vidí v artefakte a schváli **pred** odoslaním.
- E-maily odchádzajú z hi@trubbo.app s kópiou na founderov Gmail, odpovede prichádzajú do schránky hello@missinghue.com, ktorú agent číta (len na mba). Agent vedie prehľad v tomto pláne (tabuľka nižšie, bez e-mailov, repo je verejné).

## Kroky

- [~] **215.1** Agent: texty (e-mail organizátorom cs/sk, FB príspevok a správa adminovi, 4 výberové otázky, uvítanie v skupine, týždenná otázka) + zoznam kontaktov → artefakt na schválenie. 2026-10-29 hotové: https://claude.ai/artifact/9TMMNNpifxSEUK12HCu1Bh, čaká na founderovo schválenie.
- [ ] **215.2** Founder: schváli alebo upraví texty, vyberie 1–2 FB skupiny.
- [ ] **215.3** Agent pošle schválené e-maily, founder pošle FB príspevok. Odpovede zbiera agent.
- [ ] **215.4** Agent navrhne ~5 testerov podľa odpovedí, founder potvrdí. Pozvánky cez `/add-tester` do Public bety, founder dá povel na build do bety.
- [ ] **215.5** 3 týždne: raz týždenne súhrn (údaje z TestFlightu na testera, spätná väzba z TestFlightu a hello@, čo founder povie z WhatsAppu) → zoznam pripomienok do backlogu.
- [ ] **215.6** Po pár týždňoch otázka „Keby Trubbo zajtra zmizlo, ako veľmi by ti chýbalo?“ (veľmi / trochu / vôbec). Kto chce pokračovať a je to obojstranne prínosné, ostáva testerom aj dlhodobo. Founder rozhodne: zľava pre zakladajúcich po spustení v App Store (napr. cez Apple kódy s ponukou), alebo bez zľavy. Ďalšia vlna áno/nie a aká veľká.

## Prehľad oslovení

| Kontakt | Rola | Oslovené | Odpoveď | Stav |
|---------|------|----------|---------|------|
| Hospodský kvíz | poradca + tipy na hráčov | — | — | text čaká na schválenie |
| Chytrý kvíz | poradca + tipy na hráčov | — | — | text čaká na schválenie |
| Košice IT Valley | tipy na hráčov | — | — | text čaká na schválenie |

## Mimo rozsahu

- Platení testeri alebo burzy testerov (BetaList, BetaFamily): ľudia odtiaľ sú väčšinou iní vývojári alebo zberatelia vecí zadarmo, kvalitu nikto neporovnával (rešerš Q5).
- Verejný odkaz na Public betu na sociálnych sieťach: príde veľa ľudí, ale nevieme, kto sú.
- Zmeny v appke kvôli testerom (napr. kód testera): pri 5 ľuďoch s e-mailovou pozvánkou netreba.
