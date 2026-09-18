# #182 — Custom pack: hrať hneď po prvej otázke (inkrementálne generovanie)

**Triage:** done (agent-side) — PR #166 MERGED 2026-09-17, rampa dávok 1/2/4/8 = follow-up PR 2026-09-18; open = deploy (quiz-pack-api s migráciou pred quiz-agent, founder súhlas), `mba` worker na novom main, founder e2e z TestFlightu

## Cieľ

Používateľ nečaká na celý pack. Kvíz sa dá spustiť, keď je hotová prvá dávka
otázok; zvyšok sa generuje na pozadí, kým hrá. Ak hráč dobehne generátor,
appka povie „pripravujem ďalšiu otázku“ a pokračuje, keď otázka dorazí.

## Prečo je to dnes nemožné (stav 2026-09-17)

- Worker (`apps/quiz-pack-api`) generuje celý pack v jednej LLM dávke a
  `PersistStage` zapisuje pack + otázky do DB až ako posledný krok; stav
  objednávky skočí `in_progress → delivered` naraz.
- Živý backend (`apps/quiz-agent`) servíruje otázku packu hneď, ako existuje
  riadok s `pack_id` (review_status sa pri packoch nefiltruje) — ale prázdny
  výsledok retrievera = koniec kvízu; nevie rozlíšiť „vyčerpané“ od „ešte sa
  generuje“.
- iOS: „Spustiť kvíz“ len pri `delivered`; v kvíze neexistuje stav „ďalšia
  otázka ešte nie je“.

## Riešenie (tri tracky, jeden PR)

### A — worker: dávkový pipeline s priebežným zápisom (`quiz-pack-api`)
- `question_packs.generation_status` (`generating | complete | failed`,
  migrácia; existujúce riadky = `complete`).
- Hlavný chod = `sourcing → rounds` (TopUpStage v inkrementálnom režime):
  dávky podľa rozvrhu **1 → 2 → 4 → 8 → 8 → zvyšok** (founder 2026-09-18:
  prvá otázka čo najskôr, batchové capy pri custom packu nie sú podstatné;
  `PACK_BATCH_SCHEDULE`, default `1,2,4,8`, posledná hodnota sa opakuje),
  každá prejde dedup → answerability → verify → score → composition a hneď
  sa **zapíše** (`PersistStage.persist_batch`). Prvý zápis vytvorí pack
  (`generating`) a nastaví `order.pack_id` — od tej chvíle je pack hrateľný.
  `actual_count` rastie priebežne. Overovanie beží po dávkach (v dávke
  paralelne); ak hráč generátor dobehne, čaká.
- Už zapísané otázky sú nemenné: composition capy ich počítajú, ale nikdy
  nevyhodia (`ctx.locked_count`).
- Koniec: floor check ako doteraz (< 80 % → order `failed`, pack `failed`,
  zapísané otázky ostávajú hrateľné); inak pack `complete`, order `delivered`.
- Retry / ARQ retry pokračuje na existujúcom packe (načíta zapísané otázky
  ako locked prefix) — žiadne duplikáty, žiadne mazanie.
- `PACK_BATCH_SCHEDULE=0` = pôvodný jednodávkový chod (rollback páka). CLI
  korpus `generate_pack.py` sa nemení — bez persist stage je TopUpStage
  presne starý backfill loop (regresný test
  `test_corpus_cli_walk_is_untouched_by_the_ramp`).

### B — živý backend: čakanie na ďalšiu otázku (`quiz-agent`)
- Pack session: `max_questions` = `target_count` packu (autoritatívne zo
  servera, nie z nastavení klienta).
- `process_answer`: keď retriever nič nevráti a pack je `generating` →
  session ostáva `asking` s `current_question_id = None`, odpoveď nesie
  `awaiting_question: true` (nie `finished`).
- Nový `POST /sessions/{id}/next-question`: long-poll (max ~8 s) na ďalšiu
  otázku; vráti `InputResponse` s otázkou, alebo znova `awaiting_question`,
  alebo `finished`, keď pack už negeneruje a nič nezostalo.

### C — iOS
- Hrateľné = `pack_id != nil` a stav nie je failed/refunded (aj počas
  `in_progress`); progress krok ukáže „N z 30 pripravených“ + Spustiť kvíz.
- `QuizState.awaitingQuestion`: obrazovka „Pripravujem ďalšiu otázku…“,
  polling `/next-question`, po dorazení normálne `askingQuestion`.

## Rozhodnutia foundera 2026-09-18
- Rampa 1 → 2 → 4 → 8 → 8 → zvyšok (max dávka 8), pôvodných 5/10 bol odhad
  agenta. Odhad času do prvej otázky: sourcing (nezmenené) + ~30–45 s
  (1 generačné volanie + 1 overenie) namiesto ~1,5–2,5 min pri dávke 5;
  celý pack má o ~2 kolá viac. Reálne číslo dá prvá objednávka.
- Nič sa nesmie pokaziť na korpusovom generovaní (CLI) — chránené testom.
- **Research na inú session:** ukázať používateľovi prvú vygenerovanú
  otázku po zaplatení a spýtať sa, či je spokojný alebo chce upraviť prompt
  (objednávku nezruší, len zmení prompt); doriešiť právo na vrátenie /
  nespokojnosť s otázkami a čo sa stane, ak appku zabije pred úpravou promptu.

## Predpoklady (founder môže zmeniť)
- Čiastočne zlyhaný pack (pod 80 %) ostáva hrateľný s tým, čo má; refund
  logika nezmenená.

## Overenie
- Backend: pytest obe suity; nové testy: incremental TopUp (persist po
  každom kole, locked prefix), migrácia, `/next-question` + `awaiting_question`.
- iOS: unit testy OrderPackViewModel (hrateľné počas in_progress),
  QuizViewModel (awaiting → asking / finished).
- E2E na zariadení = founder (objednávka z TF, štart po prvej dávke).
