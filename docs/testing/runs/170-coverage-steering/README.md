# #170 — coverage steering: run dir

Session A (2026-09-04) · task 170.1 · producer `apps/quiz-pack-api/scripts/propose_subtopics.py` (session gateway, 0 $ API).

## Files

| File | What | Status |
|---|---|---|
| `subtopics-proposal.json` | Návrh podtém pre **6 záujmových kategórií** appky (`science-nature, history, geography-world, movies-music, sports, food-everyday`) + `entertainment` — 20 podtém na kategóriu, model `claude-fable-5` (session) | **schválené 2026-09-04 (všetkých 140), + top-up kolo podľa founder poznámky** |
| `subtopics-proposal-legacy-taxonomy.json` | Ten istý návrh pre zvyšných 8 id generačnej taxonómie `CATEGORIES` (`general, adults, kids, wizarding-world, superheroes, disney, football, sports-mix`) | záložný — použije sa iba ak founder ponechá starú taxonómiu |

Schválený výsledok ide až v Session B do `apps/quiz-pack-api/app/generation/subtopics.json` — tieto súbory sú návrh, runtime ich nečíta.

## Ako schváliť (brána F1)

1. Rozhodnúť taxonómiu (viď issue-170 § „Taxonómia — rozpor zistený v Session A"): odporúčanie = 6 záujmových + `entertainment`.
2. V príslušnom JSON škrtať / dopĺňať / prepisovať podtémy. Pravidlá: krátka anglická fráza, **≤ 64 znakov** (DB stĺpec), **≥ 10 na kategóriu**, bez duplicít; podtéma = široké územie (desiatky rôznych otázok), nie jedno dielo/osoba.
3. Zistiť kategóriu experimentu (prod, read-only): `fly proxy 15432:5432 -a quiz-pack-db` → `SELECT category, count(*) FROM questions WHERE pack_id IS NULL GROUP BY 1 ORDER BY 2 DESC, 1;`
4. Schválený JSON + výsledok dotazu odovzdať Session B (prompt v `docs/issues/issue-170-execution-prompts.md`).

Inšpirácia do promptu: medzinárodná časť banky tém „Kvíz, please!" (`../podcast-kvizplease-2026-09-03/themes-160-episodes.md`), české národné témy vynechané.

## Brána F1 — uzavretá 2026-09-04

Founder odpovedal cez artefakt „Brána F1 pre #170“ (https://claude.ai/code/artifact/4790561e-c91a-441c-9e75-201333ce8fcf): R4 oddelená vetva `feat/170-coverage-dedup`, R1 6 záujmových + entertainment, R2 approved+pending, R3 všetkých 140 podtém ponechaných; poznámka: viac „každodenných“ podtém a viac entertainmentu. Kategória experimentu podľa R2 = `general`. Súhrn sedenia: `session-a-summary.md`.
