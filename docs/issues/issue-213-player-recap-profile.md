# #213 — Prehľad hráča (Wrapped) a záložka Profil

**Triage:** enhancement · ready-for-agent
**Founder:** 2026-10-27/28 · rešerš [player-recap-wrapped-2026-10-27.md](../research/player-recap-wrapped-2026-10-27.md) · návrh obrazoviek https://claude.ai/artifact/TZdKxSW2v1rdzncgCedQiV

## Cieľ

Hráč vidí zábavné štatistiky o tom, ako hrá (silná kategória, kde a kedy hrá, bežná hra, zlepšovanie, najrýchlejšia kategória), kedykoľvek v novej záložke Profil. Mesačne a ročne dostane prehľad ako príbeh na snímkach, ktorý vie zdieľať na Instagram a TikTok.

**Hotovo, keď:** Profil s kartami beží v appke (sk/cs/en), karty sa odomykajú podľa prahov, mesačný prehľad sa vytvorí sám, posledná snímka sa dá zdieľať ako obrázok, a meriame otvorenie aj zdieľanie.

## Rozhodnutia foundera

| Kedy | Rozhodnutie |
|---|---|
| 10-27 | Len smer Spotify Wrapped. Pohyb telefónu, hlas, váhanie, emócie NIE. |
| 10-27 | Rytmus: mesačne + ročne (december), štatistiky kedykoľvek v appke. |
| 10-27 | Celé zadarmo. Zdieľateľná karta hneď v prvej verzii. |
| 10-28 | Dolná lišta **B**: dve záložky „Hrať“ a „Profil“. Balíčky a nastavenia idú do Profilu. Počas kvízu lišta skrytá. |
| 10-28 | Profil **variant 1**: prehľad navrchu, mriežka kariet, zamknuté karty s postupom, nastavenia pod ozubeným kolieskom. Príbehové snímky schválené („super“). |
| 10-28 | Nastavenia treba premyslieť: dostupné z Home aj z obrazovky kvízu, iné pre solo a hru spolu. |
| 10-29 | Sekcia „Moje balíky“ ostáva na Home (rýchle spustenie), Profil dostane riadok „Moje balíky“. |
| 10-29 | Nastavenia hry spolu = samostatný krok 213.8: najprv HTML návrhy (napr. v lobby hostiteľa), predvolené hodnoty majú vyhovovať väčšine. Ku každej novej funkcii hneď aj meranie. |

## Prahy (z rešerše)

- Prvý prehľad: 60 odpovedí v 3+ dňoch (~40 min hry, prod: ~40 s na otázku).
- Mesačný: 30+ odpovedí v 2+ dňoch v mesiaci, inak sa mesiac ticho preskočí.
- Ročný: 150+ odpovedí, dáta do 30. novembra.
- Každá karta má vlastný prah (tabuľka v rešerši). Prahy sú konfigurácia na serveri, aby sa dali prepočítať bez buildu.

## Hranice

- Žiadne AI vo výpočte, len počty nad `analytics_events` (+ `daily_challenge_answers`).
- Žiadne nové povolenia v appke. Poloha nie.
- API len pridáva (nový endpoint, nové voliteľné vlastnosti udalostí), živé buildy fungujú ďalej.
- Hra spolu (session quiz-agent-81, rešerš [multiplayer-same-room-2026-10-23.md](../research/multiplayer-same-room-2026-10-23.md)): odpovede v hre spolu sa rátajú do štatistík každého hráča pod jeho `subject_id`, s príznakom hry spolu. Tlačidlo SPOLU vedľa Štartu na záložke Hrať je s lištou B v súlade.

## Návrh dát (213.2 + 213.3)

**Zdroj.** Len `analytics_events` (server: `quiz_started`, `answer_evaluated`, `quiz_completed`; appka: `quiz_context`, `answer_submitted`). Hráč = všetky jeho identity: účet + naviazané anonymné id (`linked_anon_ids`), ako `data_export`. Udalosti bez `subject_id` sa ignorujú. **Opravené hodnotenie:** úprava prepisu (`resubmission.py`) dnes žiadnu udalosť nezapisuje, takže v dátach ostáva prvý, prebitý verdikt. 213.2 preto pridá `answer_evaluated` s `is_regrade=true` aj pri opätovnom hodnotení a štatistiky berú **posledný** verdikt na `(session_id, question_id)`, aby súhlasili so skóre z hry. Hra spolu sa ráta (príznak `multiplayer` z 212.2 len ako filter pre budúce karty).

**Výpočet pri čítaní, nie predpočítaný.** `GET /api/v1/me/stats` počíta karty z udalostí hráča pri každom volaní. Prod objem je malý (desiatky hier), na hráča ide o stovky až tisíce riadkov. Index `(subject_id, occurred_at)` nahradí samotný `subject_id` index (ďalšia voľná migrácia; 212.2 beží súbežne, číslo sa určí pri rebase, jedna hlava alembicu). Agregácia v SQL (GROUP BY nad JSONB vlastnosťami), nie načítanie všetkého do Pythonu. Cache netreba, kým jedno volanie trvá < 200 ms pri 10k udalostiach (test výkonu s vygenerovanými dátami).

**Spájanie udalostí.** Hra = rôzne `session_id` v `answer_evaluated` (nie `quiz_started`: v hre spolu ho má len hostiteľ). `quiz_context` dáva hre `audio_route` (kde) a `timezone` (miestny čas a deň). Rýchlosť = `answer_submitted.latency_ms` spojené s `answer_evaluated.category` cez `(session_id, question_id)`, len riadok s `is_retry=false` (inak sa riadky násobia). Appka posiela serverové `session_id` (overené). Udalosti appky sa pri slabom signáli môžu stratiť (len v pamäti, jeden pokus), preto má každá karta aj minimálnu vzorku, nielen hra. Hra bez `quiz_context` (staré buildy, pred 213.1) sa počíta do súčtov, ale nie do kariet „kde/kedy“; časové pásmo sa doplní z najbližšej hry toho hráča, inak UTC.

**Karty.** Pevný zoznam v kóde, každá: `kind` (reťazec, nie enum, aby nová karta nerozbila staré buildy; appka neznáme preskočí), `state` locked/unlocked, `progress {current, target, unit}`, hodnoty. Prahy v jednom konfiguračnom module servera (zmena = deploy, bez buildu appky). Zlepšenie: úspešnosť pri rovnakej obťažnosti, prvých N vs posledných N odpovedí, len ak obe vzorky ≥ prah.

**Prehľady = uložená snímka.** Tabuľka `player_recaps`: vlastník (`subject_id`), `kind` first/month/year, `period_start` (miestny kalendárny dátum `YYYY-MM-01`, nie čas, aby cestovanie medzi pásmami nevytvorilo druhý mesiac), `payload` JSONB (hotové karty + typ hráča), `schema_version`, `created_at`, `seen_at`; unikát `(subject_id, kind, period_start)`. **Vzniká lenivo, bez plánovača:** pri `GET /me/recaps` server skontroluje, či za uzavreté obdobie (predošlý mesiac v časovom pásme hráča; rok po 1. decembri, dáta do 30. 11.; prvý pri splnení prahu) snímka existuje a hráč spĺňa prah; ak áno, vytvorí ju a vráti (`INSERT … ON CONFLICT DO NOTHING`, súbežné volania sú bezpečné). Hráč, ktorý appku neotvorí, prehľad nepotrebuje. Snímka sa už nikdy neprepočíta, takže prehľad sa po čase nemení ani pri zmene prahov či vzorcov.

**Identita a mazanie.** Vlastník snímky = aktuálne `subject_id` volajúceho; čítanie berie snímky všetkých jeho identít, pri duplicite obdobia vyhráva najstaršia (už videná) snímka; nová sa vytvorí len ak žiadna identita hráča snímku za obdobie nemá. Mazanie: `player_recaps` sa pridá do `_erase_personal_trail` a do exportu dát. Odhlásenie: zariadenie dostane späť anonymné id, štatistiky z účtu nevidí (rovnako ako dnes ostatné dáta).

**Kontrola:** `/design-soundness` 10-28 — 1 chyba (opravené hodnotenia), zapracované vyššie spolu s upozorneniami.

**Mimo rozsahu.** Žiadne mazanie starých udalostí zatiaľ neexistuje (#51 — produktová analytika, otvorené); ak príde, štatistiky „za celý čas“ sa skrátia, snímky prehľadov ostanú. Denná výzva sa ráta len cez `answer_evaluated`, tabuľky dennej výzvy sa nečítajú.

## Úlohy

Poradie: 213.1 hneď (dáta sa musia zbierať pred spustením), potom 213.2 → 213.3, súbežne 213.4.

- [x] **213.1 Chýbajúce merania** (PR #615, nasadené) — časové pásmo hráča pri štarte hry (`quiz_context`), čas do začiatku odpovede (`answer_submitted.latency_ms`). Allowlist v `taxonomy.py` + iOS + `docs/product/analytics-events.md`. Malé, ide samostatne.
- [x] **213.2 Výpočet štatistík (server)** (PR #618) — služba nad udalosťami hráča: karty, stav zamknutia a postup („ešte 2 hry“). Endpoint pre appku. Porovnanie zlepšenia pri rovnakej obťažnosti. Testy na prahy a hranice (prázdny hráč, presne na prahu, jedna kategória).
- [x] **213.3 Prehľady (server)** (PR #620) — prvý, mesačný (1. deň mesiaca za predošlý), ročný (december). Uložená snímka prehľadu, aby sa po čase nemenil. Typ hráča podľa pevných pravidiel. Mazanie spolu s účtom.
- [x] **213.4 Lišta a Profil (appka)** (PR #628) — lišta Hrať/Profil (skrytá počas kvízu), Profil: účet, krúžok k prvému prehľadu, mriežka kariet (zamknuté s postupom), Moje balíky, nastavenia pod kolieskom; Home bez kolieska; udalosť `profile_opened`; snímky obrazoviek, RS-30. Rýchle nastavenia z kvízu už existujú (hárok Nastavení na obrazovke otázky). Banner prehľadu príde s 213.5.
- [ ] **213.5 Príbeh a zdieľanie (appka)** — prehrávanie snímok, posledná snímka ako obrázok 9:16 na zdieľanie. Texty sk/cs/en cez copy review, veľké nadpisy na jeden riadok.
- [ ] **213.6 Meranie** — udalosti: otvorenie Profilu, prehľad videný (koľko snímok), zdieľaný. Vyhodnotenie po prvom mesačnom prehľade.
- [ ] **213.7 Zásady ochrany súkromia** — veta o štatistikách z herných dát a o časovom pásme.
- [ ] **213.8 Nastavenia hry spolu (appka)** — odhalenie odpovedí, čas na odpoveď a hlas hostiteľa: HTML návrhy → výber foundera → kód. Predvolené pre väčšinu, meranie zmien.

## Otvorené

- Oznámenie nového prehľadu: zatiaľ len značka na záložke Profil, push notifikácie nie.
- Hráč bez prihlásenia: štatistiky „na tomto zariadení“, po prihlásení sa spoja.
