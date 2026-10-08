# #195 — Čerstvé otázky: časovo obmedzené 2× zvýhodnenie pri výbere

**Triage:** enhancement · in-progress
**Založené:** 2026-10-08 (founder: čerstvé otázky, napr. novinky zo zábavy, majú chodiť ~2× častejšie, ale len kým sú aktuálne)
**Vetva:** `feat/195-topicality-boost`

## Cieľ

Aktuálna otázka sa pri výbere ďalšej otázky ťahá s dvojnásobnou váhou, kým je téma čerstvá. Ako dlho, rozhodne LLM pre každú otázku zvlášť. Po skončení okna sa otázka správa ako bežná, **nemaže sa** (to je samostatná expirácia z #76 — dočasné otázky (`expires_at`), tá ostáva nedotknutá).

## Rozhodnutia foundera (2026-10-08)

- Zvýhodnenie = **2×** pri výbere, nie viac.
- Dĺžku určuje LLM podľa otázky: „kto mal minulý týždeň narodeniny“ → ~týždeň; „kto vyhral Oscara 2026 za X“ → rok; veľká kultúrna udalosť (Najlepší film) → natrvalo.
- Klasifikácia beží **pri každom generovaní** („pobeží pri každom generovaní“).

## Čo je postavené

- **Dáta:** stĺpec `questions.boost_until` (timestamptz, NULL = nikdy), migrácia `e195b0057a11`; ORM, zdieľaný `Question`, `pgvector_client` (tabuľka + oba prevody). „Natrvalo“ = dátum 9999-01-01 (Python neudrží Postgres `infinity`). Verdikt (úroveň, dátum udalosti, zdôvodnenie) v `provenance.extra.topicality` na kontrolu.
- **Klasifikátor** `app/generation/topicality_classifier.py` (vzor `expiry_classifier.py`): jedno dávkové volanie cez factory (rola CRITIQUE), dnešný dátum v prompte, úrovne `none / week / month / quarter / year / permanent` + `event_date`. Pevná mapa 7 / 30 / 90 / 365 dní; `boost_until = event_date + TTL`, ak už uplynulo → bez zvýhodnenia. Pri chybe nikdy nespadne, otázky ostanú bez zvýhodnenia.
- **Generovanie:** `GenerationStage` ho volá vždy; prepínač `TOPICALITY_CLASSIFICATION` (default ZAPNUTÉ, `0` vypne), zapojené vo workeri aj v `scripts/generate_pack.py`. Testy ho majú v `tests/conftest.py` vypnuté (inak neočakávané LLM volanie v order-e2e bráne).
- **Skript** `scripts/classify_topicality.py`: JSON z `generate_pack --out` → dávky po 25 → `boost_until` + verdikt späť do JSON, histogram úrovní + riadok na otázku. Funguje aj pod `LLM_GATEWAY=session`. Režim nad celou DB = neskôr.
- **Výber (quiz-agent):** `BOOST_WEIGHT = 2.0` v `question_retriever.py`; všetky tri miesta s `random.choice` (prvá otázka, top-5 rôznorodých, záloha podľa témy) sú váhový výber. Do poolu sa zvýhodnené otázky **nepridávajú** (efekt by bol oveľa viac než 2×). Žiadne LLM ani DB volanie navyše.
- **Import:** `import_questions_json.py` prenáša `boost_until` cez `Question` bez zmeny kódu (pokryté testom).

## Poradie nasadenia

1. quiz-pack-api (migrácia `e195b0057a11` cez `release_command`).
2. Až potom quiz-agent — číta všetky stĺpce `questions`, bez migrácie by výber otázok padal.

## Otvorené

- [ ] Čerstvá dávka 50 otázok en/sk/cs: vygenerovať, `classify_topicality.py`, skontrolovať verdikty, importovať (samostatný krok).
- [ ] Neskôr: režim nad DB na preklasifikovanie celého korpusu.
