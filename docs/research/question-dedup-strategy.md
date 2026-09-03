# Research: Deduplikácia otázok a tém pri LLM generovaní

**Date:** 2026-09-03 | **Query:** Ako sa škáluje deduplikácia otázok/tém s rastúcou DB? Best practices; dáva zmysel posielať kľúčové slová / hinty už do generačného promptu namiesto post-hoc odstraňovania duplikátov?

## Executive Summary

- **Detekcia duplikátov s rastom DB nedrahne.** pgvector s HNSW indexom dáva sublineárne vyhľadávanie, embedding jednej otázky stojí zlomok centu. Pri 100k otázkach je celkový embedding náklad rádovo desiatky centov. Náš `DedupStage` už na tomto stojí. Toto nie je problém, ktorý treba riešiť.
- **Čo s rastom DB skutočne rastie, je odpad:** každý duplikát, ktorý zachytíme až po generovaní, už zaplatil generovanie (a bez správneho poradia aj fact-check). A miera duplikátov rastie nie kvôli veľkosti DB, ale kvôli **mode collapse** generátora: LLM sa vracia k tým istým populárnym faktom (GPT-4o dá "7" v 92/100 pokusov o náhodné číslo; pri otvorených úlohách jedna dominantná odpoveď tvorí 67–80 % výstupov). Čím viac populárnych faktov už korpus pokrýva, tým väčšia časť nových generácií naráža na obsadené.
- **Negatívne zoznamy v prompte ("nepíš tieto otázky") nie sú škálovateľná odpoveď.** Kontext rastie lineárne s korpusom, modely dlhé negatívne zoznamy neposlúchajú spoľahlivo a existuje "pink elephant" efekt (vymenovanie zakázaného zvyšuje šancu, že sa to objaví). Náš existujúci `avoid_questions` parameter (cap 10) je mŕtve plumbing, orchestrátor ho nevolá, a je to tak dobre.
- **Best practice je pozitívne riadenie generovania:** dať modelu konkrétny fakt / entitu / uhol / typ otázky (Cosmopedia: mriežka publikum × štýl + seed pasáž → < 1 % duplikátov bez rejection stage; SimpleStrat: stratifikované vzorkovanie bije teplotu). Founderova intuícia "posielať hinty do promptu" je správna, ale ako **pozitívne hinty čo použiť**, nie ako zoznam čo nepoužiť.
- **Pre náš pipeline (od #166 je prod default priame generovanie bez faktov) to znamená: dnes generátor dostane len názov kategórie a počet, a voľne beží z vlastnej pamäte. To je najhorší možný vstup z pohľadu mode collapse.** Najlacnejšia páka je pozitívne riadenie: generátor dostane konkrétne podtémy / entity / typy otázok vybrané z najmenej pokrytých buniek korpusu, plus trvalý register odpovedí (entít), ktorý tie bunky počíta a zároveň stropuje opakované odpovede. Grounded cesta (#167) má ekvivalent už v indexe spotrebovaných faktov.

## Key Findings

### 1. Detekcia: náklad na jednu novú otázku je prakticky konštantný

HNSW index v pgvector (v0.5+) vyhľadáva sublineárne; s rastom na milióny riadkov ostáva dopyt lacný, ladí sa len recall vs. rýchlosť (`m`, `ef_construction`). Embedding cez `text-embedding-3-small` stojí $0.02 / 1M tokenov; otázka má ~20–30 tokenov, takže 100k otázok = cca $0.05 celkovo. Open modely (bge, gte, nomic) sú kvalitnejšie na MTEB, ale self-hosting sa oplatí až nad ~10M embeddingov/mesiac.

Prahy cosine similarity **nie sú prenosné medzi modelmi** (ada-002 ~0.79 pre near-dup, 3-large už ~0.3). Literatúra pre "rovnaká otázka": ~0.85 vysoká presnosť, 0.90–0.92 vyvážené; "rovnaká téma" 0.60–0.80. Produkčné QA dedup pipeline embedduje **otázku + odpoveď spolu** a prahuje na 0.90; samotný text otázky zle rozlišuje "rovnaký fakt, iný uhol" (rok vs. vek) a naopak zlieva "rovnaká téma, iná odpoveď".

Hashovacie metódy (MinHash/LSH, SimHash) sú na krátke texty preukázateľne slabšie než na dlhé dokumenty (ACM WWW 2025 benchmark) a nechytia parafrázu, ktorá je dominantný typ duplikátu pri LLM otázkach. Ich miesto: deterministický nulový filter na presné/typo duplikáty.

Náš známy gap (dedup.py:29–34): pár s cosine 0.735 (skutočný duplikát) vs. 0.738 (nie duplikát) je prahom nerozlíšiteľný. Štandardná odpoveď je **kaskáda**: hash → embedding kNN (top-5..10) → LLM sudca len pre kandidátov v šedej zóne. Kaskáda lacný sudca → silný sudca len pri neistote šetrí až 78.5 % nákladov na hodnotenie (ICLR 2025) a pridanie reasoning kroku nad embedding kandidátmi zlepšuje precision aj recall (Zilliz).

### 2. Miera duplikátov rastie kvôli generátoru, nie kvôli DB

Mode collapse je zmeraný a brutálny: pri otvorenej generácii základné modely vyčerpajú 2–4 skutočne odlišné výstupy z 10 dopytov a potom sa opakujú. Pre "daj mi ďalší fakt o X" to znamená, že marginálna otázka čoraz častejšie trafí už pokrytý populárny fakt. Implikácia: dedup infra musí škálovať s **objemom generovania**, nie s veľkosťou korpusu, a lacnejšou pákou než sprísňovanie prahov je zmena spôsobu, ako sa generátor pýta.

Generation-side mitigácie s dátami: **Verbalized Sampling** (model vypíše distribúciu viacerých kandidátov, nie jednu odpoveď) vracia 66.8 % pred-alignment diverzity a zlepšuje diverzitu 2–3× oproti priamemu promptovaniu. Teplota 0.7–0.8 je sweet spot, nad 0.9 degraduje formát a diverzitu nespoľahlivo opraví. Výber v dávke podľa maximálnej párovej embedding vzdialenosti (20 vzoriek / prompt) bije obyčajné batchovanie.

### 3. Negatívne zoznamy v prompte: fungujú len malé a cielené

Žiadna kontrolovaná štúdia nemeria dĺžku negatívneho zoznamu vs. mieru zlyhania; praktici hlásia nespoľahlivosť hlboko pod tisíckami položiek a prechod na embedding dedup. Mechanizmus "pink elephant" (negácia vyžaduje reprezentáciu zakázaného konceptu; attention negáciu zachytáva slabo) je demonštrovaný na topic-avoidance chatbotov, nie na kvízoch, takže je to varovanie, nie číslo. Kde negatívna inštrukcia **funguje**: keď je negatívny priestor malý a konkrétny (Cosmopedia: "nezačínaj 'Once upon a time'"). Priamy A/B test "celý zoznam vs. náhodných N existujúcich ako negatívne príklady" sa nenašiel.

### 4. Pozitívne riadenie: štruktúrovaný priestor promptov namiesto zákazov

- **Cosmopedia** (25B tokenov syntetického textu): seed pasáž + mriežka publikum × štýl → MinHash duplikáty **< 1 %** bez rejection stage; naivná variácia promptu bez explicitných osí dávala výrazne viac duplikátov.
- **SimpleStrat**: model si sám rozdelí výstupný priestor na strata, vzorkuje sa stratum pred generovaním; 0.36 KL redukcia vs. Llama 3, +0.05 recall vs. GPT-4o na CoverageQA.
- **VOYAGER**: predchádzajúce generácie = "preskúmané územie", nová vzorka sa prijme len ak je dosť ďaleko (coverage map, tréningu netreba).
- **Persona Hub**: 1B persón ako pozitívna páka diverzity (bez ablácie miery duplikátov).
- **Stratifikované vzorkovanie podľa taxonómie otázok** (hrubá × jemná trieda) sa používa v QA výskume práve preto, aby sa nespoliehalo na samodiverzifikáciu modelu.
- Self-Instruct/Alpaca: post-hoc ROUGE-L 0.7 filter (52 002 párov); Magpie: FAISS + mpnet, diverzita sa len meria, nie vynucuje. Teda aj klasické pipeline dedupujú post-hoc, ale tie moderné (Cosmopedia) presunuli ťažisko do dizajnu promptu.

Náklad: žiadna práca nerobí priame $/položka porovnanie. Štrukturálny argument: post-hoc rejection platí plnú generáciu + verifikáciu za každú zahodenú položku a potrebuje rastúcu referenčnú množinu; pozitívne riadenie platí zhruba fixný vstupný token náklad na volanie nezávisle od veľkosti korpusu.

### 5. Prax kvízových produktov a item bankingu

- **Jeopardy!**: hry sa zoskupujú do poolov po 5 a kontroluje sa, že "príliš podobné clues" nejdú v jednom týždni; round table ručne flaguje opakovania; 7 clues na kategóriu ako záloha; každý fakt overený dvoma nezávislými zdrojmi + kontrola, že existuje **len jedna správna odpoveď**. Reuse starých clues bol počas štrajku 2023 explicitná výnimka.
- **Open Trivia DB**: SHA-1 hash otázky pre korpusový dedup + **session token** proti opakovaniu v rámci hráčovej session. Dve oddelené vrstvy: korpusová identita vs. expozícia per hráč.
- **Item banking (assessment)**: "**enemy items**" = položky, ktoré nesmú ísť spolu v jednom teste; tagovanie na úrovni odpovedí (friend/enemy) ako metadáta položky; NLP podobnosť ako pomôcka. **AQuAP** framework (2026): automatické flagovanie pri ~85 %+ podobnosti, metriky expozície (frekvencia, kumulatív, rýchlosť), status active/flagged/deprecated, **retirement namiesto mazania**. Duolingo English Test: veľká banka + automatická generácia ako obrana proti expozícii.
- **Fact-first generovanie** (Wikidata triple → otázka, LREC 2022): jeden fakt = jedna kandidátna otázka, dedup na id faktu pred generovaním; filter tripletov na unikátnosť odpovede ako brána.
- **Novelty ako kvalitatívny signál**, nie binárny gate: min cosine k korpusu cez retrieve → rerank → kalibrácia voči ľudskej baseline (arXiv 2510.27313). Presne sedí na founderovu rubriku "surprise reward, cliché penalty".
- Pravidlo "koľko otázok na hráča za mesiac" sa v zdrojoch nenašlo; treba odvodiť z vlastnej telemetrie.

## Implications for Hangs

**Stav k 2026-09-03 (overené v kóde):** od #166 je `DIRECT_GENERATION` default zapnutý. Sourcing stage sa vráti s nulou faktov, generátor dostane iba kategóriu (+ prípadnú tému objednávky) a počet, a fact-first prompt v3 sa nepoužije. `TopicPool` sa na priamej ceste nevolá, `avoid_section` je prázdna. Grounded (fakt najprv) režim existuje len per objednávku pre entertainment (#167), kde index spotrebovaných faktov už rieši dedup pred generovaním v rámci jedného behu.

Čo už máme a je správne: pgvector + `text-embedding-3-small`, dedup pred verify (fact-check sa za duplikát neplatí), in-batch Jaccard, same-fact kľúč (zdroj + odpoveď). Detekcia nie je problém.

Čo z toho vyplýva:

1. **Priama cesta nemá dnes žiadne riadenie tém.** Model si pri "30 otázok zo science" sám vyberá fakty z pamäte, čiže presne tie populárne, ktoré korpus obsadí ako prvé. S rastom korpusu bude podiel zahodených otázok na tejto ceste rásť najrýchlejšie a každá stojí plnú generáciu. Toto je miesto, kde founderova otázka "hinty do promptu" sedí najviac.
2. **Hinty áno, ale pozitívne a konkrétne.** Namiesto "vyhni sa týmto otázkam" dostane generátor pre každú dávku pridelené bunky: kategória × podtéma × typ otázky (× obtiažnosť), vybrané z tých najmenej pokrytých v korpuse, ideálne aj s 1–2 entitami na bunku. Je to fixný token náklad bez ohľadu na veľkosť DB a presne recept, ktorý dal Cosmopedii < 1 % duplikátov. Krátky, cielený negatívny zoznam (napr. "v tejto podtéme už máme: X, Y, Z", do ~10 položiek na bunku) je v poriadku, lebo negatívny priestor je malý; celokorpusový zoznam nie.
3. **Register odpovedí / entít je lacnejší než register faktov a stačí pre priamu cestu.** Kľúč: normalizovaná odpoveď (+ hlavná entita otázky, ak ju vieme lacno extrahovať pri persist). Slúži trojako: mapa pokrytia pre bod 2, strop "max N otázok s rovnakou odpoveďou v kategórii" v `DedupStage`, a lokálny negatívny zoznam pre pridelenú bunku. Pre grounded cestu je to to isté ako `SpentFactIndex`, len trvalé naprieč behmi.
4. **Odpoveď je lepší kľúč než otázka.** Embedding otázka + odpoveď namiesto len otázky zúži známy gap "rovnaký fakt, iné slová" (cosine 0.735 vs. 0.738).
5. **Šedú zónu má rozhodovať lacný LLM sudca, nie prah.** Kandidáti s cosine ~0.70–0.85 idú na párový verdikt Haiku/Sonnet; pri malom počte kandidátov rádovo centy na dávku.
6. **Dávka ako jednotka diverzity.** Priamy prompt už generuje N otázok v jednom volaní; explicitná inštrukcia "každá o inej entite / podtéme" plus pridelené bunky je zadarmo. Verbalized sampling je lacný experiment navyše.
7. **Retire, nemaž.** Near-dup ako variant + stav active/retired; per-user opakovanie (expozícia) je samostatná vrstva na hot path.
8. **Novelty score do scoring stage.** Min cosine k korpusu ako spojitý signál "prekvapenia" podporuje founderovu rubriku; embedding už máme.
9. Housekeeping: CONTEXT.md stále opisuje ChromaDB ako živý vector store, pgvector je kanonický od #41.

## Recommendations

1. **Nezriaďovať žiadnu "dedup infra pre škálovanie".** Overiť HNSW index na `questions.embedding` (ak chýba, jednoriadková migrácia). Detekcia s rastom DB nedrahne.
2. **Coverage-driven pridelenie buniek na priamej ceste** (najväčší dopad): pri persist tagovať otázku podtémou a normalizovanou odpoveďou; pred generáciou spočítať pokrytie buniek kategória × podtéma × typ a do promptu poslať pridelené bunky pre dávku (`{topic_section}` už existuje, dnes prázdna). Zoznam podtém na kategóriu = jednorazový offline krok (obdoba `TopicPlanner`).
3. **Register odpovedí + strop** v `DedupStage` (napr. max 3 otázky na normalizovanú odpoveď v kategórii) + embedding otázka+odpoveď. Prahy prekalibrovať na ratovanej dávke, keďže sa mení vstup embeddingu.
4. **Cielený krátky negatívny zoznam na bunku** (≤ ~10 položiek: už obsadené odpovede/entity v pridelenej podtéme) cez existujúcu `{avoid_section}`. Nikdy celokorpusový zoznam.
5. **LLM sudca pre šedú zónu** 0.70–0.85. Rieši zdokumentovaný gap z #153.
6. **Diversity experiment** (lacný, jednorazový, na session gateway): pridelené bunky + "každá o inej entite" vs. dnešný prompt; merať dedup drop rate a novelty na rovnakej kategórii.
7. **Novelty score** ako dimenzia scoring stage; stav `retired` namiesto delete.
8. Per-user expozícia riešiť ako samostatný issue na hot path.

Rozhodnutia foundera (2026-09-03):
- Strop na opakované odpovede **per kategória**, nie globálne.
- Duplikát v korpuse **nie je tragédia**; cieľ je nízky odpad, nie nulová tolerancia.
- **Custom packy sú nezávislé od globálneho korpusu:** generujú sa z promptu používateľa, nerecyklujú z voľného korpusu, a prekryv s korpusom nevadí. Dedup pack ↔ korpus sa nerobí.
- Neskorší UX nápad (mimo tento issue): používateľ otaguje otázku ako duplikát a dostane náhradnú zadarmo; potrebuje anti-abuse check (limit + overenie podobnosti pred priznaním).
- Otvorené ostáva: podtémy pre bunky ručne (~10–20 na kategóriu) vs. návrh modelom + schválenie.

## Sources

1. [Understanding vector search and HNSW index with pgvector](https://neon.com/blog/understanding-vector-search-and-hnsw-index-with-pgvector) — sublineárne vyhľadávanie, ladenie HNSW
2. [text-embedding-3-small pricing](https://openrouter.ai/openai/text-embedding-3-small) — $0.02/M tokenov
3. [OpenAI Community: cosine similarity thresholds](https://community.openai.com/t/rule-of-thumb-cosine-similarity-thresholds/693670) — prahy nie sú prenosné medzi modelmi
4. [Benchmarking Near-Duplicate Detection (ACM WWW 2025)](https://dl.acm.org/doi/10.1145/3701716.3715303) — MinHash/SimHash slabé na krátke texty
5. [Fine-Grained Benchmark Generation (arXiv 2605.18824)](https://arxiv.org/pdf/2605.18824) — otázka+odpoveď embedding, 0.90, kaskáda s LLM sudcom, generation-time avoidance
6. [Trust or Escalate: LLM Judges with Provable Guarantees (ICLR 2025)](https://proceedings.iclr.cc/paper_files/paper/2025/file/08dabd5345b37fffcbe335bd578b15a0-Paper-Conference.pdf) — kaskáda sudcov, −78.5 % nákladov
7. [Data Deduplication at Trillion Scale (Zilliz)](https://zilliz.com/blog/data-deduplication-at-trillion-scale-solve-the-biggest-bottleneck-of-llm-training) — reasoning nad embedding kandidátmi zlepšuje P/R
8. [Deja Vu at Scale (arXiv 2604.20462)](https://arxiv.org/abs/2604.20462) — failure modes parafrázového dedupu
9. [Entity Linking with Wikidata (ACM CSUR)](https://dl.acm.org/doi/10.1145/3795134) — kanonizácia odpovede na QID
10. [You can't ask an LLM to be "more random"](https://springboards.ai/blog-posts/you-cant-ask-an-llm-to-be-more-random) — čísla mode collapse
11. [Verbalized Sampling (arXiv 2510.01171)](https://arxiv.org/abs/2510.01171) — 2–3× diverzita, 66.8 % recovery
12. [Cosmopedia README](https://github.com/huggingface/cosmopedia/blob/main/README.md) — < 1 % duplikátov cez mriežku publikum × štýl + seed
13. [SimpleStrat (arXiv 2410.09038)](https://arxiv.org/abs/2410.09038) — stratifikované vzorkovanie vs. teplota
14. [VOYAGER (arXiv 2512.12072)](https://arxiv.org/pdf/2512.12072) — coverage map bez tréningu
15. [Scaling Synthetic Data Creation with 1B Personas](https://arxiv.org/html/2406.20094v3) — persóny ako pozitívna páka
16. [Do not think about pink elephant! (arXiv 2404.15154)](https://arxiv.org/html/2404.15154v1) — mechanizmus zlyhania negatívnych inštrukcií
17. [The Pink Elephant Problem (16x.engineer)](https://eval.16x.engineer/blog/the-pink-elephant-negative-instructions-llms-effectiveness-analysis) — anekdotická evidencia, sám sa označuje za nerigorózny
18. [Synthetic Data Generation Using LLMs: survey (arXiv 2503.14023)](https://arxiv.org/html/2503.14023) — prechod z negatívnych zoznamov na embedding dedup
19. [Self-Instruct Framework, Explained](https://towardsdatascience.com/self-instruct-framework-explained-16bce90f4683/) — ROUGE-L 0.7, Alpaca
20. [Multi-Sample Prompting (arXiv 2506.21138)](https://arxiv.org/pdf/2506.21138) — výber v dávke podľa embedding vzdialenosti
21. [Can LLMs Ask Good Questions? (arXiv 2501.03491)](https://arxiv.org/html/2501.03491v2) — stratifikácia podľa taxonómie otázok
22. [Jeopardy! Clue Lifecycle](https://www.jeopardy.com/jbuzz/behind-scenes/control-room-lifecycle-jeopardy-clue) — pooly po 5, round table, dva zdroje, jedna odpoveď
23. [Open Trivia DB](https://opentdb.com/) — SHA-1 + session token
24. [Assessment Systems: Enemy Items](https://assess.com/enemy-items/) — enemy items, tagovanie odpovedí
25. [AQuAP (arXiv 2606.18536)](https://arxiv.org/pdf/2606.18536) — pool health, expozícia, retirement
26. [Responsible AI for Test Equity, DET (arXiv 2409.07476)](https://arxiv.org/pdf/2409.07476) — veľká banka ako obrana proti expozícii
27. [Generating Questions from Wikidata Triples (LREC 2022)](https://aclanthology.org/2022.lrec-1.29.pdf) — triple → otázka
28. [LLM generation novelty via semantic similarity (arXiv 2510.27313)](https://arxiv.org/html/2510.27313v2) — novelty ako spojitý signál kvality
29. [Deduplication near-duplicate guide](https://aquibjkhan.medium.com/deduplication-near-duplicate-a-short-guide-b7ecbf348f97) — semhash 0.99, praktické recepty
