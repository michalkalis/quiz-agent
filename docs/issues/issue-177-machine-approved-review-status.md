# #177 — Strojové schválenie: čisté EN otázky idú pri importe rovno do `approved`

**Triage:** `ready-for-human` · founder rozhodnutie 2026-09-10 · mení pravidlo z 2026-08-28 (PR #81)
**Stav:** T1–T6 implementované 2026-09-10 na vetve `feat/177-machine-approved-review-status` (oba backend suity zelené); čaká review + merge
**Súvisí:** #176 (TF štítky), #168 (coverage bary počítajú approved-only EN), CONTEXT.md „Review status × build channel“

## Prečo

Founder 2026-09-10: „App Store verzia môže zobrazovať aj otázky, ktoré neboli schválené človekom, ale len tie v stave SCHVÁLENÉ“ a „tie, čo sú schválené a bez issues, môžu byť hneď approved“. Dnes importér stampuje všetko `pending_review` (len TestFlight) a `approved` vyžaduje ľudský verdikt. Nový stav: anglická otázka, ktorá prešla všetkými strojovými bránami **bez jediného nálezu**, ide rovno do `approved`; akýkoľvek nález ostáva `pending_review`.

## Rozhodnutia (nerozporovať)

- `approved` = „človek ALEBO strojové brány bez nálezu“; rozhoduje stav, nie kto ho nastavil.
- Stroj sa od človeka odlíši cez `reviewed_by = "machine:gates-v1"` (ľudia ostávajú `michal`). Verzia brány sa zvýši, keď sa zmení sada kontrol.
- Bez `source_url` nikdy approved (pravidlo „zdroj povinný“). `language != en`, `pack_id` nastavené, chýbajúca provenance (ručne kurátorované) → nikdy auto-approved.
- Admin endpoint `POST /api/v1/admin/questions/import` ostáva stroju slepý (payload nemá `source_url`, gate dôkazy by boli falšovateľné) — auto-approval žije len v dôveryhodnom CLI importéri.
- **Otvorené pre foundera (neblokuje):** otázky s `factcheck_tier == "evergreen"` nikdy neprešli webovým fact-checkom — auto-approve áno/nie? Do rozhodnutia = `pending_review`.

## Nálezy (recon 2026-09-10)

- Vstup do korpusu: `generate_pack.py:384-399` `_write_out` (stampuje `pending_review`) → `scripts/import_questions_json.py:88` (`--review-status`, default `pending_review` na `:189`; `:66-79` `_verification_block_reason` = #158 hard reject). `reviewed_by` sa nikdy nezapisuje.
- Brány **dropujú, netagujú**: prežitie = pass pre dedup, answerability (`stages/answerability.py:47-66`), verification (`stages/verification.py:171-221`), distractor + score (`stages/scoring.py:312-355`). Persistuje sa len `generation_metadata.extra`: `verified`, `verification_score`, `verification_notes`, `held_for_review`, `factcheck_tier`.
- **Diera:** ponechané-ale-flagnuté riadky nenechajú stopu — craft-guard shadow (`scoring.py:262-277`), `undated_record_reason` (`:245-256`), veto shadow (`:279-310`); judge skóre žijú len v `ctx.scores`.
- Legacy `scripts/prepare_import.py:122` stampuje `approved` zo strojového verdiktu a píše neplatný status `needs_review` — existujúci priestupok, opraviť alebo označiť deprecated.
- Spotrebitelia: `question_retriever.py:278-287`, `question_monitor.py:99-106`, `app/generation/storage.py:53-54` (ticho degraduje approved→pending_review v pending store).

## Tasks (atomic)

- [x] **T1** Persistovať shadow flagy: `stages/scoring.py` zapíše `extra["craft_flag"]`, `extra["undated_flag"]`, `extra["veto_flag"]` (reason stringy, ktoré už počíta) do `generation_metadata` pred ponechaním otázky. AC: flagnutá-ale-ponechaná otázka prenesie dôvod cez `_write_out` → `Question.from_dict`; `StageResult.info` čítače nezmenené; testy v `tests/orchestrator/stages/test_scoring.py`.
- [x] **T2** Predikát `machine_approval_block_reason(q, tf_excess) -> str | None` v `apps/quiz-pack-api/app/scoring/machine_approval.py` (nie shared: reuse `craft_guards`). **Fail-closed** na každé chýbajúce/neznáme pole; staré JSON dávky bez flag kľúčov → recompute cez `craft_guards` (pure funkcie), nie „čisté“. Podmienky: `language == "en"`, `pack_id is None`, `source_url` neprázdne, provenance prítomná, `extra.verified is True`, `verification_score >= DEFAULT_MIN_CONFIDENCE (0.5)`, nie `held_for_review`, žiadny craft/undated/veto flag, `factcheck_tier != "evergreen"` (do founder rozhodnutia). AC: unit test na každý reject dôvod + jeden čistý EN riadok → `None`.
- [x] **T3** Importér: `--review-status` default `auto` — per riadok čistý → `approved` + `reviewed_by="machine:gates-v1"` + `reviewed_at=now`; inak `pending_review`. Explicitné `pending_review`/`approved` stále vynútia všetky riadky (ľudská promócia). AC: dry-run vypíše approved/pending počty + top block dôvody; #158 guard beží pred predikátom; `language_dependent`/`pack_id` sa nemenia.
- [x] **T4** Admin endpoint: komentár na `admin.py:76`, prečo auto-approval nie je tu. AC: existujúci test default-pending ostáva nezmenený.
- [x] **T5** Testy: `tests/scripts/test_import_questions_json_guard.py:74` (default je `auto`; + čistý→approved, flagnutý→pending), docstringy `:1-11` a `apps/quiz-agent/tests/test_admin_import_review_status.py:1-13`. `test_generate_pack_flags.py:138,:343` platné, `_write_out` ďalej stampuje `pending_review` (rozhoduje importér). AC: plný pytest zelený v oboch appkách.
- [x] **T6** Docs: `CONTEXT.md:82,88` — `approved` = „človek alebo gates-v1“, `reviewed_by LIKE 'machine:%'` = strojový marker; re-import nepromuje existujúce riadky (`add()` = ON CONFLICT DO NOTHING, backfill mimo rozsahu). `prepare_import.py` označiť deprecated alebo opraviť `needs_review`.

## Riziká

- Dávky pred T1 nemajú flag kľúče → predikát musí rekomputovať, nie predpokladať čisté.
- „Všetky brány“ = brány tak, ako sú nakonfigurované (`JUDGE_GATE=0`, sudcovia OFF) — povedať to vo verzii brány.
- #168 coverage bary: strojové approvals zväčšia EN menovateľ → ratio bary prísnejšie (HG-4 pre TF už waivnutá, App Store konštanty prehodnotiť pri cutovere).
- `storage.py:53` by ticho degradoval strojové approved, ak by nejaká cesta re-upsertla cez pending store — overiť, že importér tam nechodí.

## Akceptácia

- Čistá EN otázka so zdrojom po `import_questions_json.py` (default) = `approved`, `reviewed_by=machine:gates-v1`; s akýmkoľvek flagom = `pending_review`.
- Bez `source_url` / evergreen / ne-EN / pack = nikdy approved.
- Admin endpoint default nezmenený. Backend testy oboch appiek zelené.

## Poznámky z implementácie (2026-09-10)

- Recon riadky sa posunuli: `_write_out` je `generate_pack.py:434` (nie `:384`), shadow bloky v `scoring.py` sú craft `:259-287`, undated `:244-257`, veto `:289-310`; admin `review_status` pole je `apps/quiz-agent/app/api/admin.py:75-83` (súbor je `app/api/admin.py`, nie `app/api/v1/admin.py`). `prepare_import.py` je v **root** `scripts/`, nie v quiz-pack-api.
- Flag kľúče + writer (`stamp_review_flag`) žijú v `app/scoring/machine_approval.py` spolu s predikátom — jeden modul = nemôžu sa rozísť; `ScoringStage` ich importuje.
- `MIN_VERIFICATION_SCORE = 0.5` je v predikáte zduplikované (import `verification.py` by do CLI importéra vtiahol LLM verifikátory); test ho pinuje na `DEFAULT_MIN_CONFIDENCE`, takže drift padne nahlas.
- Sprísnenie nad rámec zadania (fail-closed): vyžaduje sa `factcheck_tier == "web"`, čiže nielen „nie evergreen" — chýbajúci/neznámy tier je neznámy dôkaz. `language` musí byť explicitne `"en"` (NULL nestačí, hoci inde v kóde NULL ≈ en).
- Craft/undated nálezy sa pri importe **vždy** prepočítajú z riadku (nie len keď chýbajú flag kľúče); `veto_flag` prepočítať nejde (žije zo sudcovských dimenzií), blokuje len keď je zapísaný — pri `JUDGE_GATE=0` je inertný, čo je dôvod verzovania `machine:gates-v1`.
- Riziko zo `storage.py:53` overené: importér píše priamo `pg_insert(... ON CONFLICT DO NOTHING)`, pending store neobchádza, takže strojové `approved` sa nemá kde degradovať.
- T1 testy sú v novom `tests/orchestrator/stages/test_scoring_review_flags.py` (pôvodný `test_scoring.py` má ~800 riadkov, limit ~300).
