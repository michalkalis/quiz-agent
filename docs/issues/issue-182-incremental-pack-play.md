# #182 — Custom pack: hrať hneď po prvej otázke (inkrementálne generovanie)

**Triage:** done (agent-side) — PR #166 otvorený 2026-09-17; open = merge, deploy (quiz-pack-api s migráciou pred quiz-agent), `mba` worker na novom main, founder e2e z TestFlightu

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
  prvá dávka malá (`PACK_FIRST_CHUNK`, default 5), ďalšie `PACK_CHUNK_SIZE`
  (default 10), každá prejde dedup → answerability → verify → score →
  composition a hneď sa **zapíše** (`PersistStage.persist_batch`). Prvý zápis
  vytvorí pack (`generating`) a nastaví `order.pack_id` — od tej chvíle je
  pack hrateľný. `actual_count` rastie priebežne.
- Už zapísané otázky sú nemenné: composition capy ich počítajú, ale nikdy
  nevyhodia (`ctx.locked_count`).
- Koniec: floor check ako doteraz (< 80 % → order `failed`, pack `failed`,
  zapísané otázky ostávajú hrateľné); inak pack `complete`, order `delivered`.
- Retry / ARQ retry pokračuje na existujúcom packe (načíta zapísané otázky
  ako locked prefix) — žiadne duplikáty, žiadne mazanie.
- `PACK_FIRST_CHUNK=0` = pôvodný jednodávkový chod (rollback páka; CLI
  korpus `generate_pack.py` sa nemení).

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

## Predpoklady (founder môže zmeniť)
- Veľkosť dávok 5 / 10; menšie dávky = viac LLM volaní na pack (fixná réžia
  promptu), odhad +10–20 % generačných nákladov, kvalita per otázka rovnaká
  (rovnaké brány).
- Čiastočne zlyhaný pack (pod 80 %) ostáva hrateľný s tým, čo má; refund
  logika nezmenená.

## Overenie
- Backend: pytest obe suity; nové testy: incremental TopUp (persist po
  každom kole, locked prefix), migrácia, `/next-question` + `awaiting_question`.
- iOS: unit testy OrderPackViewModel (hrateľné počas in_progress),
  QuizViewModel (awaiting → asking / finished).
- E2E na zariadení = founder (objednávka z TF, štart po prvej dávke).
