# #208 — TF test 2026-10-16: hlasové povely, prepis odpovede, stavy kvízu

**Triage:** bug · in-progress
**Status:** 208.0 nasadené (prod STT = OpenAI); tracky 208.1–208.8 v práci
**Založené:** 2026-10-16 (founder testuje TF build z `main`, sk, reproduktor iPhonu, „Posielať nahrávky“ ON)
**Súvisí:** #204 — rozpoznanie odpovede (A/B prepínače), #197 — nahrávky z auta (replay), #185 — test v aute, #173 — stlmenie počas jazdy

## Dáta z testu (prod, 13:11–13:42 UTC)

- **30 odpovedí:** 18 skončilo detekciou ticha, 9 na strope 8 s, 3 bez reči; **13 z 30 server zahodil** (prázdny prepis / „žiadna odpoveď“).
- Všetkých 9 stropov 8 s bolo s energetickou detekciou (neurónová 0/14, energetická 9/16, ale skoro všetky v jednom kole, takže prostredie je zmiešané). Ostáva na automatickom A/B (204.9).
- **Prepis (replay 30 nahrávok; report mimo repa, repo je verejné):** ElevenLabs Scribe v2 nepočul nič alebo nezmysel tam, kde OpenAI `gpt-transcribe` (s textom otázky ako kontextom) počul správne: „Reset hesiel“ (4 z 5 opakovaní), „Kapitalizmus“, „Rubikova kocka“, „Harper's Bazaar“, „Váh“. Scribe navyše hádzal 429 (system busy).
- **Povely:** prvá hypotéza rozpoznávača medián 1,1 s (max 16 s); 21 prepisov zahodených, lebo okno už bolo zavreté; počas čítania otázky na reproduktore mikrofón nepočúva vôbec, hoci lišta ponúka „zopakuj / preskoč“.
- **Hlasitosť:** pri štarte sa audio prepne do režimu hovoru (`VoiceChat`) kvôli počúvaniu povelov na domove a iOS prepne aj na hlasitosť hovoru (0 → 0,55 → 0 → 0,05).

## Rozhodnutia foundera (2026-10-16)

- **Prepis odpovede:** OpenAI ako hlavné; ElevenLabs STT v aktuálnej verzii **úplne odstrániť** (ElevenLabs nemá lepší model, Scribe v2 je najnovší; TTS ostáva).
- **Znova na potvrdení:** dve rovnako veľké tlačidlá vedľa seba, Znova vľavo, Potvrď s odpočtom vpravo.
- **Hláskovanie:** nápoveda až po prvom Znova pri tej istej otázke.
- **Bez čítania nahlas:** tichá pauza na prečítanie (odpočet stojí plný), potom bežný odpočet.
- **Odozva povelu:** problém nie je potvrdenie, ale ticho od chvíle, keď hráč začne hovoriť. Appka má hneď ukázať „počujem“ a po dohovorení „spracúvam“ (dnes reaguje až o 1–2 s).
- **Stlmenie čítania** platí aj pre ďalší kvíz, kým ho hráč nezmení (ruší pôvodný zámer #173, kde bolo stlmenie len na jedno kolo).

## Tracky

| Track | Nález | Čo | Kde |
|---|---|---|---|
| 208.0 | 4, 11 | `STT_PROVIDER=openai` na prode (Fly secret, v168) | ops ✅ |
| 208.1 | 4, 11 | Backend: OpenAI `gpt-transcribe` je jediné STT odpovede (opakovanie raz pri chybe), Scribe z cesty odpovede preč; `/elevenlabs/token` ostáva kvôli starším buildom (1.0, 1.1 v review) | backend |
| 208.2 | 6 | Hláskovanie: deterministické spojenie písmen (P-A-R-Í-Ž, „pé á er í žet“, sk/cs/en názvy písmen) pred vyhodnotením, okrem MCQ; veta v prompte sudcu; overiť replayom | backend |
| 208.3 | 7 | Čas spracovania: časy jednotlivých krokov v logu (STT, parser, sudca, TTS), prefetch ďalšej otázky paralelne, prečítanie prepisu syntetizované na serveri súbežne s hodnotením (bez ďalšej cesty z appky) | backend + iOS |
| 208.4 | 1, 8, 10 | „Čítam otázku“ len keď TTS naozaj číta; bez čítania tichá pauza podľa počtu slov (~2,5 slova/s, min 3 s, max 15 s), potom odpočet; stlmenie z hlavičky sa uloží do nastavení | iOS |
| 208.5 | 3, 9 | Domov počúva povely bez režimu hovoru (hlasitosť neskáče); Moje balíky ostanú zobrazené po kvíze, obnovia sa na pozadí | iOS |
| 208.6 | 5, 6 | Potvrdenie: dve rovnaké tlačidlá; po prvom Znova nápoveda na hláskovanie | iOS |
| 208.7 | 2 | Povely: okamžité „počujem“ z úrovne mikrofónu nad hlukom, „spracúvam“ po dohovorení, potom ✓ slovo; povely aj počas čítania otázky, keď trasa má potlačenie ozveny (reproduktor/HFP s voice processing); preskoč a pauza už zo stabilného priebežného výsledku; úrovne v okne povelov do logu | iOS |
| 208.8 | 11 | Appka: preč prepínač „Prepis v reálnom čase“ a ElevenLabs Realtime z cesty odpovede; diktovanie spätnej väzby a hodnotenia cez dávkový prepis na serveri; RS testy na dávkový mock | iOS + backend |

Poradie: 208.0 → 208.1 → (208.2, 208.3, 208.4, 208.5, 208.6 paralelne) → 208.7 → 208.8.
Každý track = vlastný PR do `main`; iOS sa overí na simulátore (18 Pro) a na zariadení s ďalším TF buildom na požiadanie.

## Kedy hotovo

- Povel povedaný normálnym hlasom na reproduktore: lišta do ~0,2 s ukáže „počujem“, po dohovorení „spracúvam“, povel sa vykoná na prvý raz.
- Replay dnešných 30 nahrávok: žiadna zreteľne povedaná odpoveď nevyjde prázdna; hláskované „V A H“ / „P-A-R-Í-Ž“ sa spoja do slova.
- Čas od konca reči po obrazovku „Povedal si“ je v logu po krokoch, s mediánom pred a po.
- Nálezy 1, 3, 5, 8, 9, 10 overené na simulátore; 2, 3, 4, 7 na zariadení (TF build na požiadanie).

## Stav

- 2026-10-16: 208.0 nasadené (v168, health OK).
