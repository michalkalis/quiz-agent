# Kategória experimentu (#170 task 170.3 · zapísané 2026-09-07)

**Kategória experimentu: `general`.**

Pravidlo 170.2 po brána F1 rozhodnutí R2 (živé riadky = `approved` + `pending_review`, archív a rejected sa nerátajú):

```sql
SELECT category, count(*) FROM questions
WHERE pack_id IS NULL AND review_status IN ('approved','pending_review')
GROUP BY category ORDER BY count(*) DESC, category ASC LIMIT 1;
```

Výsledok (prod, read-only cez `fly proxy`, 2026-09-04 — plná tabuľka v `prod-category-counts-2026-09-04.md`):

| category | živé (approved + pending) |
|---|---:|
| general | 81 |
| science-nature | 81 |
| movies-music | 62 |
| geography-world | 40 |
| history | 40 |
| sports | 30 |
| food-everyday | 28 |
| entertainment | 21 |

Remíza `general` 81 : `science-nature` 81 → tie-break abecedne → **`general`**. Poznámka pre Session J/K: `general` nie je v schválenej taxonómii podtém (R1 = 6 záujmových + `entertainment`), takže pred quality-guard behom treba buď (a) prekategorizovať živé `general` riadky do záujmových kategórií (deterministická topic→category tabuľka `scripts/recategorize_corpus.py` existuje), alebo (b) zvoliť druhú v poradí `science-nature`. **Rozhodnutie odložené** spolu s celým class-`b` blokom (founder 2026-09-04: nič do produ, kým duplikáty nebolia).

Schválená taxonómia podtém: `subtopics-approved-2026-09-07.json` (199 podtém · 7 kategórií; kolo 1 = 140, kolo 2 = 59 z 60, vyradené „Airports, airlines and airport codes“).
