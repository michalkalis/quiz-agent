# Issue #211 — Prirodzené sk/cs otázky (bez prilepenej domácej vety a kalkov)

**Triage:** enhancement · done (2026-10-23)

**Created:** 2026-10-22 · **Founder:** Michal · Súvisí: #203 (nudné otázky, štýl domu), #206 (štítok lokálnych otázok)

## Problém

Founder pri revízii lokálnosti (#206): *„Krčmové kvízy, pri ktorých tímy súťažia nad pivom, dnes nájdete v Bratislave, Košiciach aj v menších mestách. Z ktorej krajiny tento formát zábavy pôvodne pochádza?“* Znie to divne a „cringe“: „súťažia nad pivom“ je kalk z angličtiny („over a pint“) a veta o Bratislave a Košiciach nič nepridáva.

## Príčiny (overené v kóde 2026-10-22)

1. **Kvóta 7 z 10 bez hranice.** Domáci odsek štýlu domu (`prompts/house_style.md`) žiada ~7/10 otázok o krajine. Pri všeobecnom fakte ju model splní najlacnejšie: prilepí mesto. Výskum to opisuje ako povrchné kultúrne značky pri výslovnom „buď lokálny“ ([2504.10191](https://arxiv.org/html/2504.10191v1), [AIES 2025 localized word problems](https://ojs.aaai.org/index.php/AIES/article/download/43321/50881/47427)).
2. **Model rozmýšľa po anglicky.** Šablóna `question_generation_direct.md` („writing in English for a broad international adult audience“), štýl domu aj ukážky sú anglické; slovenčina je len dodatok, ktorý dovoľuje `reasoning` po anglicky. Výsledok: anglický „prízvuk“ v slovníku a syntaxi ([2410.15956](https://arxiv.org/html/2410.15956v1)).
3. **Žiadna kontrola jazyka pri natívnom generovaní.** MQM sudca s kategóriami kalkov (`app/translation_verification/judge.py`) a pravidlo stavby vety (`translation_runner/translate.py`) bežia len na prekladoch; corpus behy majú `--no-judges`.

Pozn.: hák sám nie je zlý. Founder dal 9/10 otázke „Kým na Slovensku je na Štedrý večer kapor so šalátom, v ktorej ázijskej krajine…“ (kontrast so skutočným zážitkom hráča). Zlý je hák, ktorý nič nenesie.

## Rozhodnutia foundera (2026-10-22)

- **Kvóta 7 z 10 ostáva.** Pridá sa hranica: do domácej sedmičky sa počíta len otázka, ktorej fakt je naozaj domáci, alebo kde domáci zážitok nesie pointu.
- **Fakt zo zdroja ako prvý krok NIE.** Už sme to mali: D21 (#164) grounded v3 8,00 vs direct 8,38 na tom istom modeli; #72 RC-5 povinný fakt zabíja nápaditosť.
- Áno: zadanie po slovensky a po česky s natívnymi ukážkami · pravidlo stavby otázky vo všetkých jazykoch · kontrola prirodzenosti ako upozornenie, nie stopka · upratanie existujúcich sk/cs otázok.
- Všetko rovnako pre češtinu.

## Prístup

Všetko za prepínačom `GEN_HOUSE_STYLE_V2` (predvolene vypnutý): štýl domu je od 10-14 živý v prode pre vlastné balíky (`GEN_HOUSE_STYLE=1`), kvalita sa nesmie zmeniť bez slepého kola.

- **Štýl domu v2:** `house_style_v2.md` (en) + `house_style_v2.sk.md` + `house_style_v2.cs.md`, sk/cs napísané natívne (nie preklad), s founderovými 9–10 otázkami v danom jazyku ako ukážkami a pár zlými príkladmi (kalky, prázdny hák). Obsah = doterajší vkus + tvrdé pravidlá + nové pravidlo stavby („každá časť otázky pomáha odpovedať alebo baví“) + domáci odsek s hranicou. Sekcia výstupného jazyka pri v2 natívne a `reasoning` v jazyku otázky.
- **Technický kontrakt šablóny ostáva anglický** (JSON, pravidlá pravdivosti). Predpoklad: štýl a jazyk robí štýlová časť; ak pilot nepomôže, ďalší krok je preložiť celú šablónu.
- **Kontrola prirodzenosti:** dávkový klasifikátor (tvar `local_scope_classifier.py`), Sonnet 5.5, pre sk/cs vráti na otázku `{ok, problems[{kind, quote}], rewrite}`; `kind` = kalk · prázdny hák · neprirodzená väzba · gramatika. Ukladá sa do `provenance.extra.naturalness`. Nič neblokuje: AI hodnotitelia sú v menších jazykoch nespoľahliví a uprednostňujú preklad ([2505.12201](https://arxiv.org/pdf/2505.12201), [2603.10351](https://arxiv.org/html/2603.10351)) → rozhoduje slepé hodnotenie foundera.
- **Upratanie:** ten istý klasifikátor ako backfill na schválené sk/cs otázky (`--sample` / `--execute`, ako #206). Prepis sa použije až keď founder v slepom páre (pôvodná vs prepísaná, ~10 párov na jazyk) potvrdí, že prepis je lepší.

## Úlohy

- [x] **211.1 Štýl domu v2** (PR #545, 2026-10-22; vypnutý) (sk/cs natívne + en pravidlo stavby), prepínač, pečiatka verzie, testy hranice (hák bez pointy zakázaný, kontrastný hák povolený, kvóta ostáva).
- [x] **211.2 Kontrola prirodzenosti** (PR #546, nasadené 2026-10-22, zapnutá; Opus 5.5): modul + prompt + testy, hook v importéri (sk/cs), prepínač `NATURALNESS_CHECK`.
- [x] **211.3 Pilot** (2026-10-22, `docs/testing/runs/natural-sk-cs-2026-10-22/`, 6 tém × 2 otázky, predplatné, 57 otázok naslepo; founder hodnotil „zbežne“). Zábava súčasný A vs v2 B: sk 8,3 vs 8,1 (šum), cs 7,5 vs 8,4, en 7,8 vs 8,3, spolu 7,86 vs 8,25; šanca 57/57; „neznie prirodzene“ A 2 vs B 0. Kontrola prirodzenosti: A 10 vs B 4 z 20 sk/cs; označené 7,9 vs neoznačené 8,2, founder pritom označil za neprirodzenú len 1 zo 14 → kontrola chytá jemné chyby (urazit, opření, „pod Rysmi“), ktoré pri rýchlom čítaní nevadia; prepisy sú vecne správne. Gate splnený → 211.5. Mimo: med z egyptských hrobiek (B-en) má slabý zdroj (stránka neotvorená), founder ho už raz spochybnil → neimportovať.
- [x] **211.4 Upratanie korpusu** (2026-10-23, `docs/testing/runs/naturalness-backfill-2026-10-23/`). Backfill 824 sk/cs riadkov, označených 135 ($2,73). 1. kolo naslepo: prepis 15/20 → 15 nasadených. Prompt v2 (najmenšia úprava, PR #560) + poistka proti azbuke (PR #561); re-check 115 → 45 označených. 2. kolo naslepo: v2 prepis 11 lepší / 3 rovnaké / 2 horšie (čiarka, jedno slovo) zo 16; 4/4 kontrolné riadky, ktoré v2 pustil, boli s prepisom lepšie → prompt v3 = citlivosť v1 + úpravy v2 (PR #564); suchý beh 2/40 falošných na ok riadkoch. Nasadené: 43 v2 prepisov (bez 2 prehratých), 39 v3 prepisov zo 41 (ručne vynechané 2: vecná nepresnosť „na ktorých“, skutočne domáca Miková pri Warholovi). Spolu 97 riadkov prepísaných, originál v `provenance.extra.naturalness.original_question`, prenovené vektory; nič nevyradené. `NATURALNESS_AUTOFIX=1` na Fly (founder 10-23 „opraviť automaticky“), nasadené. Founder poznámky k obsahu (nie k jazyku): S15 prezrádza odpoveď, S13/S18 „nič moc otázka“.
- [x] **211.5 Zapnutie** (2026-10-22, founder „zapni“: Fly secret `GEN_HOUSE_STYLE_V2=1` na quiz-pack-api; týždenný job ho má pripnutý na 0, PR #551; recept `general-corpus-recipe.md`; mba záložný worker zatiaľ bez neho, beží len pri výpadku Fly): `GEN_HOUSE_STYLE_V2=1` (prod + mba worker), recept `general-corpus-recipe.md` a `fresh-entertainment-recipe.md` na v2.

## Hotovo keď

- Pilot naslepo: v2 ≥ súčasný recept v sk aj cs (a en nie horšie), priemer ≥ 7.
- Nové sk/cs otázky majú štítok prirodzenosti bez ručného kroku.
- Existujúce označené sk/cs otázky prepísané alebo vyradené podľa schváleného postupu; počty nahlásené. ✓ 97 prepísaných, 0 vyradených.
- Testy zelené, PR cez review + CI, nasadené. Žiadny TF build.
