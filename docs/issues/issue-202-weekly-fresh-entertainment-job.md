# #202 — Týždenné automatické dopĺňanie čerstvej zábavy

**Triage:** enhancement · in-progress
**Založené:** 2026-10-13 (founder: „na backende stačí, keď bude bežať job, ktorý bude pravidelne kontrolovať a dopĺňať otázky“)
**Súvisí:** #195 (čerstvá zábava, 2× zvýhodnenie), #199 (stráženie zásoby), #201 (recept: [fresh-entertainment-recipe](../setup/fresh-entertainment-recipe.md)), #196 (Claude priamo cez Anthropic API + kredit)

## Cieľ a kedy je hotovo

Každú stredu ráno server sám vygeneruje čerstvé otázky zo zábavy natívne pre en, sk a cs podľa receptu #201 a nahrá ich do produ. Čo prejde strojovými bránami, ide rovno do App Store (`approved`, `machine:gates-v1`), ostatné do `pending_review` (len TF). Bez cloud agenta a bez Macu, cez Anthropic API (kredit z Max, potom bežný zostatok).

**Hotovo** = (1) ručný skúšobný beh na sucho pre všetky 3 jazyky dá otázky, ktoré spĺňajú recept; (2) ostrý ručný beh ich nahrá a stav zásoby sa zvýši; (3) founder dá súhlas a zapne sa pravidelný beh; (4) prvý plánovaný beh v stredu prebehne a pošle súhrn.

## Rozhodnutia foundera (2026-10-13)

- Beží na backende, nie v cloud routine ani na mba.
- Streda ráno (čerstvé na víkend).
- Natívne per jazyk: sk/cs ~7 z 10 domáca scéna (celebrity, reality šou, domáce hity), zvyšok svetové megahity. en sa do sk/cs **neprekladá**.
- **~15 vygenerovaných otázok na jazyk** každý týždeň (nie „len čo chýba“).
- **Tvrdý strop $15 na beh**; po dosiahnutí stop + hlásenie.
- Keď sa minie mesačný API kredit z Max, beh pokračuje z bežného zostatku (stále pod stropom).
- Čo prejde bránami → App Store hneď.

## Návrh

### Kde to beží
Jednorazový Fly stroj z aktuálneho obrazu `quiz-pack-api` (`fly machine run … --rm`, reštart nikdy), spustený naplánovaným GitHub Actions workflow `fresh-topup.yml` (cron `0 3 * * 3` UTC = 05:00 Praha v lete, 04:00 v zime; `workflow_dispatch` so vstupmi `languages`, `dry_run`). Stroj má dostať secrets appky (Anthropic, OpenAI na embeddingy, DATABASE_URL, Sentry), takže do GitHubu ide len app-scoped deploy token `FLY_TOPUP_TOKEN` (dedenie secrets overiť v 202.5 ako prvé; `--vm-memory 1024` explicitne, `[[vm]]` z fly.toml sa na `machine run` nevzťahuje a 256 MB zabilo workera).

Prečo nie ARQ cron vo workeri: Fly `worker` je zámerne zastavený, kým objednávky idú na session frontu (`docs/setup/session-worker-mba.md`), a ten istý `WorkerSettings` beží aj na mba cez predplatné. Cron tam by buď nebežal, alebo by išiel z predplatného. Prečo nie stále bežiaci stroj: platili by sme ho 7 dní za 1 h práce. Repo je verejné, Actions minúty sú zadarmo (rovnaký vzor ako `prod-monitor.yml`).

Vstupný bod: `python -m app.corpus.fresh_topup --languages en,sk,cs [--dry-run]`. Odmietne bežať pri `LLM_GATEWAY=session` (nikdy z predplatného).

### Krok 1 — semienka (seedy) na serveri
- Pageviews z Wikimedie (top článkov za posledných 7 dní + minulý mesiac v jazyku hráča) ako zdroj nápadov: logika z `scripts/entity_fame.py` presunutá do `app/sourcing/wiki_fame.py`, skript ostane ako tenký obal.
- Jedno volanie Claude (Opus 5.5) na jazyk s nástrojmi `web_search` + `web_fetch`, prompt = pravidlá sekcie „Seeds“ receptu. Výstup ~36 kandidátov {téma, článok na Wiki, domáce/svet, dátum udalosti, fakt, uhol, source_url}. Fakt prejde len s URL, ktorú nástroj naozaj vrátil (vzor z `app/sourcing/openai_web_search_source.py`; `_anthropic_text_and_urls` :265 treba rozšíriť o `web_fetch_tool_result`, inak vypadnú seedy overené len cez fetch), dôveryhodnosť domény cez `classify_credibility`.
- Deterministické filtre: bez URL / bulvár preč, sláva (`views`) → dolná tretina preč, ~25 seedov. Podiel domácich pre sk/cs sa zapíše do súhrnu (varovanie pod 60 %).

### Krok 2 — zoznam už pokrytých faktov
Dotaz z `docs/testing/runs/fresh-entertainment-2026-10-12/covered.py` presunutý do `app/corpus/covered.py` s rovnakým filtrom (všetky jazyky, nie rejected, `pack_id IS NULL`, len znenia s aktuálnym alebo minulým rokom, `covered.py:42-46`) + strop ~300 najnovších riadkov. Významové duplicity aj tak chytí pgvector dedup.

### Krok 3 — generovanie
- `PackGenerator.run` s objednávkou v pamäti ako `generate_pack._build_order` (`direct`, `entertainment`, natívny jazyk, brief). Zostava stupňov z `generate_pack._build_stages` presunutá do app modulu, skript ju volá (jedna definícia). Bez `PersistStage` (ten by stampol `pack_id`), dedup proti živému korpusu (pgvector), `floor_fraction=0`, 15 otázok na jazyk.
- Brief = čistá funkcia `build_fresh_brief(lang, today, seeds, covered)` podľa ramena B z `docs/testing/runs/gettable-entertainment-2026-10-13/run_arm.sh` + odseky receptu; okno čerstvosti počítané od dátumu behu (~10 týždňov späť).
- **Celá mapa rolí pripnutá** na to, čo reálne bežalo v hodnotených session behoch (usage súbory `gettable-entertainment-2026-10-13/B-*.usage.json`, alias tabuľka `factory.py:296-307`): generovanie aj critique Opus 5.5 (bez 15 % Fable, `GEN_ALT_SHARE=0`), overovanie faktov `claude-sonnet-5-5` s web search (Anthropic cesta), zodpovedateľnosť `claude-haiku-5-5` pre en a `claude-sonnet-5-5` pre sk/cs, dedup sudca `claude-sonnet-5-5`, logický overovač Opus 5.5, casual-player vypnutý, sudcovia vypnutí. Job pri štarte vyrieši všetky roly a **skončí s chybou, ak sa niektorá líši** od mapy (prod secrets `LLM_ROLE_*`, `VERIFY_MODEL`, `JUDGE_MODELS`, `LLM_GATEWAY` by ich inak ticho zmenili). Mimo Anthropicu tak ide len embedding (OpenAI). Aktuálnosť (`boost_until`) pečiatkuje už `GenerationStage`.

### Krok 4 — nahranie
Jadro `scripts/import_questions_json.py` presunuté do `app/corpus/importer.py` (`import_questions(…, review_status="auto")`), CLI ostane obalom bez zmeny správania (opraviť zastaraný docstring „auto-approve len en“, `import_questions_json.py:11-13`; kód povoľuje en/sk/cs). Navyše pred importom: bez `source_url` alebo v inom jazyku → zahodiť. `boost_until` prechádza cez `question_to_row`.

### Strop útraty a kredit
- Útrata = tokeny z `UsageRecorder` (fact-check tam ide cez `record_direct`, `fact_verifier.py:324`) + poplatky za web search fact-checku (`ctx.cost_cents` mínus jeho tokeny, `fact_verifier.py:329-332`) + server-tool poplatky seed volania (`usage.server_tool_use`). Nič sa nepočíta dvakrát. Každý model v mape rolí musí mať cenu, inak štart zlyhá (žiadne tiché $0).
- Jazyk sa začne len vtedy, keď zostatok do `FRESH_TOPUP_MAX_USD` (default 15) ≥ najhorší prípad jazyka (seedy + generovanie s top-up kolami `MAX_TOPUP_ROUNDS`); prvý odhad $6, potom z nameraných behov. Poradie jazykov sa každý týždeň otáča, aby pri strope nevypadával vždy ten istý (cs). Seed volanie má `max_uses` (search ~20, fetch ~15) a `max_content_tokens` pre fetch.
- Kredit z Max sa neriadi: keď sa minie, beh pokračuje z bežného zostatku pod tým istým stropom (founder 2026-10-13). `credit_gate` sa v jobe nepoužíva, takže netreba mesačne prepisovať dátumy kreditu.

### Hlásenie
- Sentry Crons check-in `fresh-topup` (zmeškaný alebo zlyhaný beh = e-mail, ako alerty #199).
- Jedna Sentry správa so súhrnom na beh: na jazyk seedy, vygenerované, approved / pending / zahodené s dôvodmi, útrata. Warning, keď je niečo pending, preskočené alebo strop.
- Denná kontrola zásoby (#199) ostáva ako poistka.

### Vypínač
`FRESH_TOPUP_ENABLED` v GitHub premennej repa: plánovaný beh je no-op, kým founder nedá súhlas. Ručné spustenie (`workflow_dispatch`) funguje vždy.

## Úlohy

- [x] 202.1 Presuny bez zmeny správania: importer, zostava stupňov, wiki_fame, covered + testy parity (CLI a funkcia dajú rovnaké stavy).
- [x] 202.2 Seed researcher (Claude + web search/fetch) + filtre + testy.
- [x] 202.3 Orchestrátor `app/corpus/fresh_topup.py` (brief, generovanie, import, strop, mapa rolí, Sentry súhrn + check-in) + testy.
- [x] 202.4 Workflow `fresh-topup.yml` + `FLY_TOPUP_TOKEN` + premenná vypínača.
  - Odchýlky: stroj bez `--rm` (odstránený stroj stratí exit kód; workflow ho po skončení zmaže sám), Sentry Crons check-in len pri plánovanom behu (`--cron-checkin`), aby ručné/suché behy pred zapnutím nezaložili monitor, ktorý by potom hlásil zmeškané stredy. ShapeClassifier dostáva rovnaký pin ako zodpovedateľnosť. Moduly: `app/corpus/{seed_research,seed_filters,fresh_brief,fresh_roles,fresh_generate,fresh_report,fresh_topup}.py`.
- [ ] 202.5 Nasadenie, ručný beh na sucho en/sk/cs → founder pozrie vzorku.
- [ ] 202.6 Ostrý ručný beh → stav zásoby → súhlas foundera → zapnúť plánovaný beh.

## Testy (zámer)
- Pri `session` gatewayi job odmietne bežať (nikdy z predplatného).
- Strop zastaví ďalší jazyk, keď sa najhorší prípad nezmestí; útrata zahŕňa fact-check a server-tool poplatky.
- Mapa rolí: prod `LLM_ROLE_*` v prostredí → job skončí s chybou ešte pred prvým volaním.
- Seed filtre: bez URL, bulvár, dolná tretina slávy vypadnú; podiel domácich sa reportuje.
- Brief: cs nahrádza Slovak → Czech, dátumy podľa dňa behu, obsahuje seedy, pokryté fakty, „bez ocenení/štábu“ a „čísla len MCQ“.
- Zostava: žiadny PersistStage, pgvector dedup, Opus pripnutý, Sonnet zodpovedateľnosť len sk/cs.
- Import: riadok bez URL / v cudzom jazyku vypadne, `boost_until` dorazí do riadku, opakovaný import nepridá nič.

## Riziká
- Bez ručnej kurácie (`merge.py` predtým ručne vyhadzoval zastarané a prezradené). Filtrom sú len brány + `pending_review`; súhrn v Sentry slúži na náhodnú kontrolu.
- sk/cs seedy: top články Wikipédie sú plné politiky a kriminality → prompt ich vylučuje (pravidlo „bez aktuálnej politiky a vojen“), overiť na suchých behoch.
- Prod secrets `quiz-pack-api` (overené 2026-10-13): `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `DATABASE_URL`, `SENTRY_DSN` sú. Prod má vlastné `LLM_GATEWAY`, `LLM_ROLE_GEN`, `LLM_ROLE_CRITIQUE`, `VERIFY_MODEL`, `JUDGE_MODELS` → job ich musí prepísať v prostredí svojho stroja (`--env`), inak by Claude išiel cez OpenRouter mimo kreditu.
- Ďalší beh v ten istý týždeň znamená ďalších ~15 otázok na jazyk (dedup proti korpusu zabráni duplicitám obsahu).
