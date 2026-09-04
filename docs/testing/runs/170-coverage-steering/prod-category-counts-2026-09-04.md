# Prod korpus — rozdelenie kategórií (read-only, 2026-09-04, vstup pre bránu F1)

`fly proxy 15432:5432 -a quiz-pack-db` · `questions WHERE pack_id IS NULL` · spolu **949** riadkov (pack riadky: 45) · `language` NULL: **240**, `en`: 709.

| category | approved | pending_review | archived | rejected | live (appr.+pend.) | spolu |
|---|---:|---:|---:|---:|---:|---:|
| adults | – | – | 307 | – | 0 | 307 |
| general | 18 | 63 | 70 | 1 | **81** | 152 |
| science-nature | 51 | 30 | – | – | **81** | 81 |
| movies-music | 35 | 27 | – | – | 62 | 62 |
| kids | – | – | 52 | – | 0 | 52 |
| geography-world | 13 | 27 | – | – | 40 | 40 |
| history | 16 | 24 | – | – | 40 | 40 |
| superheroes | – | – | 34 | – | 0 | 34 |
| sports | 6 | 24 | – | – | 30 | 30 |
| sports-mix | – | – | 30 | – | 0 | 30 |
| wizarding-world | – | – | 30 | – | 0 | 30 |
| food-everyday | 9 | 19 | – | – | 28 | 28 |
| football | – | – | 22 | – | 0 | 22 |
| entertainment | 21 | – | – | – | 21 | 21 |
| disney | – | – | 20 | – | 0 | 20 |

## Čo z toho plynie (Session A → brána F1)

1. **Dotaz z 170.2 bez filtra stavu vyberie `adults` (307 archivovaných riadkov).** Archív = vyradený korpus (07-26), nesmie riadiť ani výber kategórie experimentu, ani mapu pokrytia. Návrh: každý korpusový dotaz #170 (170.2, D1 mapa, D6 strop, D2 počty) filtruje `review_status IN ('approved','pending_review')` — obe sú živé (approved = prod, pending = TestFlight). S týmto filtrom: `general` 81 = `science-nature` 81 → tie-break abecedne → **`general`**; len approved → **`science-nature`** (51). Founder rozhodne, ktorý stav sa počíta.
2. **Rozpor taxonómií je živý:** 63 nových `general` riadkov čaká na review, lebo generátor nevie emitovať 6 záujmových id (`normalize_category` → `general`). Živé riadky sú inak takmer celé v 6 záujmových kategóriách + `entertainment`; staré fandom/vekové id majú 0 živých riadkov.
3. 240 riadkov s NULL `language` → presne prípad D2 backfillu (`language='en'`).
