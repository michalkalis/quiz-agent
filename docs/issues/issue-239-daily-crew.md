# #239 — Partia v dennej výzve (týždenná tabuľka s kamarátmi)

**Triage:** ready-for-agent · enhancement
**Session:** quiz-agent-47 · 2026-11-18

## Cieľ

Súťaž s kamarátmi, ktorá drží ľudí viac dní, bez nových krokov v appke. Partia sa poskladá sama z ľudí, s ktorými si si poslal dennú výzvu odkazom (#232 — zdieľanie kvízu odkazom). Na konci dennej výzvy vidíš týždennú tabuľku partie. Návrhy A/B/C: https://claude.ai/artifact/RkMrXQ8LhGmcvQdHdBJDzp, rešerš `docs/research/seasonal-themes-and-competition-2026-11-18.md`.

## Rozhodnutia foundera (2026-11-18)

| Téma | Rozhodnutie |
|------|-------------|
| Variant | „dajme zatiaľ len B, nekomplikujme appku novými features… naša appka nie je Ponor“ |
| Mená | meno z appky (napísané v profile, inak krstné meno z Apple, inak automatické „Rýchly gepard“), rovnako ako pri „Zahraj si môj kvíz“ |
| Odísť | odobrať jedného človeka; odobratý ťa potom tiež nevidí |
| Body | za vzácnosť, hneď („to je vlastne super“): správna odpoveď, ktorú vedeli všetci, 10 bodov, čím menej ľudí ju vedelo, tým viac, najviac 100; sčítané za pondelok až nedeľu |

## Pravidlá

- **Kto je v mojej partii:** človek, ktorý otvoril môj odkaz na dennú výzvu, alebo ktorého odkaz na dennú výzvu som otvoril ja. Len priame spojenie; kamaráti mojich kamarátov sa navzájom nevidia (rovnaké pravidlo ako porovnanie v #232 z 2026-11-14).
- Človek = všetky jeho id (anonymné aj účet), ako v #232 a #205.
- **Týždeň** = od pondelka do dňa výzvy, ktorý hráč práve hrá (jeho lokálny dátum). Body = súčet bodov za vzácnosť z dokončených denných výziev v tom týždni, v ktoromkoľvek jazyku. Body za otázku = 10 + 90 × (1 − podiel tých, čo ju vedeli, zo všetkých, čo na ňu v ten deň a jazyk odpovedali, vrátane hráča). Počítajú sa živo, takže sa menia, ako hrajú ďalší.
- V tabuľke sú len tí, ktorí tento týždeň hrali, alebo s ktorými som sa spojil tento týždeň. Najviac 20. Ja som tam vždy, ak mám aspoň jedného člena.
- **Odobratie:** obojstranné, platí natrvalo, aj keď si neskôr znova pošlete odkaz. Je uložené pre všetky id človeka.
- Zmazanie údajov zmaže aj odobratia (oboma smermi).

## Úlohy

- [x] 239.1 Server: tabuľka partie a odobratie
  - Nové endpointy: týždenná tabuľka a odobratie človeka.
  - Za rovnakou bránou ako denná výzva.
  - Pridať k zmazaniu účtu.
  - Pridať analytiku.
- [x] 239.2 Server: v bete otvorí odkaz na dennú výzvu priateľovi jeho vlastnú dennú výzvu. Dnes to závisí len od celkového prepínača, preto v bete vznikne bežné kolo a partia by sa nevytvorila.
- [x] 239.3 Zásady ochrany súkromia (sk/cs/en; uk stránku dopĺňa #231 — ukrajinčina, PR #859): ľudia, s ktorými si si poslal dennú výzvu, vidia tvoje meno a body za týždeň a môžeš ich odobrať.
- [x] 239.4 Appka: sekcia „Tvoja partia · tento týždeň“ na konci dennej výzvy.
  - Odobratie cez kontextové menu s potvrdením.
  - Bez partie sa ukáže jeden riadok, ktorý vysvetľuje, ako partia vznikne.
  - Testy pomalej a zlyhanej odpovede: sekcia sa neukáže a nič neblokuje.
- [ ] 239.5 Test v Trubbo Beta na dvoch zariadeniach (founder).

## Hotovo, keď

Dvaja testeri v bete si pošlú dennú výzvu odkazom a obaja vidia na konci výzvy toho druhého s bodmi za týždeň. Odobratie skryje oboch navzájom. Verzia v App Store nevidí nič nové.
