# #165 — Zmraziť D21 otázky ako eval set

**Triage:** enhancement · done
**Status:** DONE 2026-08-18 (commit `5c5fee0b`). Eval set `docs/testing/eval-sets/d21-2026-08.jsonl` (88 riadkov, žiadne chýbajúce labely), flags v `docs/testing/runs/d21-round-2026-08-15/svitlanka_flags.json` (ručný pass, 22 flagged riadkov, 10 hard-error), helper `apps/quiz-pack-api/scripts/eval_d21_set.py` reprodukuje judges Spearman .242 (`--include-duplicates`) + verify recall 4/10 (likely_wrong proti fact/logic/stale flagom, precision 1.0). README v eval-sets adresári.

## Cieľ

Zmraziť 88 ohodnotených otázok z kola D21 (batch `c1f109ec-9cc9-432c-88fd-d41e39292aec`)
ako trvalý eval set pre budúce ladenie promptov, modelov a vrstiev pipeline —
aby sa každá ďalšia zmena dala zmerať proti ľudským ratingom bez nového
hodnotiaceho kola.

## Obsah eval setu (per otázka)

- otázka + odpoveď + vysvetlenie + rameno (model, prompt, režim) + téma
- michal skóre 1–10 (**produktová os** — primárny label)
- editorské nálezy zo svitlanka osi ako binárne flagy: faktická chyba /
  logická diera / zastaraný údaj / duplicita (16 dup položiek označiť —
  vylučujú sa z kvality, hodia sa na dedupe testy) + pôvodný komentár
- replay výstupy vrstiev (critique, answerability, judges, verify) pre
  kalibráciu — už spočítané v `replay_results.json`

## Zdroje

Všetko lokálne v `docs/testing/runs/d21-round-2026-08-15/`:
`mapping.json` (blind→arm), `ratings_export.jsonl`, `replay_results.json`,
per-arm `*.json`. Editorské flagy treba ručne/LLM klasifikovať zo svitlanka
komentárov (~25 netriviálnych, zvyšok clean) — zoznam chýb je v issue-164
§ Os 2.

## Kroky

- [x] Skript `scripts/build_d21_eval_set.py` → jeden commitnutý JSONL
      (`docs/testing/eval-sets/d21-2026-08.jsonl`), deterministický join
      podľa `blinded_qid`
- [x] Klasifikácia svitlanka komentárov na flagy (fact/logic/stale/dup) —
      súčasť skriptu alebo jednorazový ručný pass, výsledok v JSONL
- [x] README riadok v eval-sets adresári: čo je label, čo je flag, ako
      počítať korelácie (Spearman proti michal; recall proti flagom)
- [x] Krátky helper na vyhodnotenie nového judge/vrstvy proti setu
      (Spearman + recall) — môže byť rozšírenie `correlate_d21.py`

## Kritérium hotovosti

Commitnutý eval set (88 riadkov, žiadne chýbajúce labely), helper vypočíta
Spearman existujúceho judges panelu proti michal osi a zreprodukuje .24
z kola D21.
