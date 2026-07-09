# Founder Question-Quality Calibration — 2026-07-09

**Purpose:** Ground-truth rubric for what makes a quiz question *fun / production-worthy* vs. *boring / defective*, distilled from a live 36-question rating session with the founder (the subjective arbiter of quality). Feeds the #72 generation-quality overhaul and the reviewer/scoring step.

**Method:** 36 questions sampled from the production corpus (565 approved), stratified across 5 generation waves. Founder rated each 1–5 with a verbatim reason. Raw log: `scratchpad/ratings_log.md` (this session). This doc is the synthesis.

> ⚠️ **Sampling caveat:** the production DB's newest questions are **May 19 (pre-regression, `v2_cot`/themed = the *good* creative path)**. The genuinely newest, arguably-degraded output (`v3_fact_first` + GPT-4o, e.g. the `data/audit-2026-06-18/` set) was **not** in this sample. Principles below are era-independent, but the low-end (boring recall) is under-represented — see Plan for the follow-up rating of the June set.

---

## Empirical result: quality by wave (founder avg)

| Wave | Date | Pipeline | n | Avg | Read |
|------|------|----------|---|-----|------|
| 1 | Dec 2025 | legacy | 5 | **3.00** | classic wiki recall |
| 2 | Mar 12 | themed | 5 | **3.00** | padded descriptive geography |
| 3 | Mar 19 | **v2_cot** | 5 | **4.50** | "did-you-know" fact-first — **peak** |
| 4 | May 4–5 | themed | 7 | **4.36** | strong |
| 5 | May 19 | v2_cot/themed | 10 | **4.20** | strong facts, craft defects drag it |

Quality **peaked at the March `v2_cot` wave and has drifted down since** — the empirical twin of the founder's "it used to be better" intuition and of #72's dated-regression diagnosis (2026-05-20). The newest wave's facts are often 5/5, but recurring **craft defects** create low outliers.

---

## What makes a question GREAT (4–5/5)

1. **Fun-fact character, not a hard wiki datum.** The best questions read as "did you know…", not encyclopedia lookups. (mile=1000 paces 5/5; strongest muscle 4/5)
2. **Genuine surprise / "I never realised that."** An aha-moment or myth-buster. (Cleopatra closer to Moon landings than the pyramids 5/5; Wilhelm Scream 5/5; Point Nemo → ISS astronauts 5/5)
3. **A hidden layer behind something familiar** — etymology, origin, inside story. (Dumbledore = Old English for "bumblebee" 5/5; Lion King Zulu chant 5/5)
4. **Forces active thinking / mental imagery / deduction**, not passive recall. Even an interrogative opener scores high if it makes you *work*. (Country shaped like an umbrella → UK 4.5/5; two dancing islands → NZ 4/5: "I feel I have a chance to guess vs fact-based boring questions")
5. **You come away having learned something worth knowing.** ("glad I learned it")

## What makes a question WEAK (1–3/5)

1. **Overexposed cliché** — seen on quizzes a million times. (King of Pop 2/5; Monopoly-banned-in-USSR: "seen too many times")
2. **Plain first-degree recall, no idea behind it.** (Who directed Inception 3/5; element named after periodic-table creator 2/5 "very common, boring, very factual")
3. **A landmark/marker in the stem hands you the answer** = passive recall. (Christ-the-Redeemer→Rio 3/5; Opera House→Sydney 2.5/5)
4. **Padded multi-clue stems.** Founder, emphatically: *"it doesn't make sense to list properties of something. Either there's ONE satisfactory point, or the question doesn't make sense."* (Rome-by-listed-properties 1/5; Sydney 2.5/5). One sharp clue beats a pile of them.
5. **Vague stem + arguable/unfalsifiable answer.** ("what is special about cocoa butter's melting point" 2/5: "not sure the answer is even logically correct")

---

## Craft defects — independent of fact quality; the reviewer MUST catch these

These are *why the newest wave feels "not great, not terrible"*: the fact is often 5/5, but construction undercuts it.

| Defect | Rule | Examples |
|--------|------|----------|
| **Answer-leak in the stem** | The answer must not be readable from the question text. | Jaws "two-**note** theme… how many notes?" → Two (leaked); Napoleon "…came from **British** propaganda… which country?" → Britain (leaked) |
| **T/F answer bias → guessable** | **VERIFIED: 32 of 34 T/F questions in the corpus are "True" (94%).** Always-guess-true wins. | Curling, Stanley Cup, Golf, Walt-Disney all True. Founder spotted it from 2 samples. |
| **Telegraphed T/F** | A long self-justifying true statement always reads as true. | Stanley Cup ritual, Golf 22-holes |
| **Unguessable open answer** | A fascinating fact with a specific number/target that can't be reasoned out must not be a free-text/open question. | spider-silk "stops a jumbo jet" (anything can weigh that); Moon "3.8 cm/yr"; LEGO "300 M tyres"; Cy Young "511". Founder: *"there seem to be more of this problem in multiple questions — tackle systematically."* |
| **Ambiguous / multi-part answer** | The accepted answer must be short and unambiguous so the voice grader can judge it. | 1904 marathon: is "driving" enough or is "11 miles" required? 3-litre-jug procedure (long multi-step) hard to grade |
| **"Which came first" that follows the default guess** | Only works when the answer *defies* expectation. | Pinocchio novel-before-film 3.5/5 ("usually books come first, not surprising") vs Black Panther hero-before-party (counterintuitive) 3/5+ |

**Not a defect:** interrogative openers (which/who/what/where/when) are **not banned** — founder explicit. They merely *correlate* with lazy recall, so scrutinise them harder.

---

## Format & answerability (part pipeline, part app/UI)

- **Fun is primary, but the answer must be short — max a few words** (founder's explicit tradeoff ruling). Frame creative questions so the answer stays crisp and gradable.
- **True/false → render as MCQ** (two options). App/UI concern, but generation should tag accordingly.
- **Numeric "estimate the number" → MCQ or an accepted range.** Guessing "300 million" blind is unfair and ungradeable. Founder prefers MCQ.
- **Concrete transform rule (founder's own):** turn a telegraphed T/F into a direct question — e.g. Golf "…22 holes, true/false?" → *"How many holes did St Andrews originally have?"* (MCQ). Extract the surprising number from the stem and ask it.

## Audience / categorisation (product)

- **Niche fandom recall** (Marvel chronology 3/5) is fine for fans but shouldn't dominate *general knowledge* — route to dedicated categories.
- **BUT** a niche topic with a surprising hidden-layer reveal works for everyone (Dumbledore 5/5). Topic isn't the gate; the *reveal* is.
- **Open product question (founder):** which categories belong in the general-knowledge pool vs. dedicated packs? — decide with founder.

---

## One-line scoring heuristic

> A great question pairs a **genuinely surprising, worth-knowing fact** with **clean craft**: the answer is short, unambiguous, *not* leaked or guessable, and the stem carries one sharp hook rather than a pile of clues. Fun first — but always gradable in a few words.

---

---

---

## Appendix — full raw rating log (verbatim founder quotes)

Ratings scale 1–5 (5 = best). Round 1 feedback in Slovak, round 2 in English (per founder — questions are generated in English). Some questions marked "unrated" where the founder declined to score (overexposed / not their domain).

### Round 1 (Q1–16)

| # | wave | topic | question (short) | rating | founder reason (verbatim) |
|---|------|-------|------------------|--------|---------------------------|
| 1 | dec2025 | History | figure buried in 3 countries (Copernicus) | 4/5 | "dal by som 4 z 5. zaujimava, necakana. male minus za to ze sa pyta na konkretneho cloveka, ale to je relativne ok." |
| 2 | dec2025 | Movies | who directed Inception (Nolan) | 3/5 | "nic moc. jednoducha velmi, otazka zacinaju 'who', tj nic prekvapive, klasicka wiki otazka bez napadu. 3 z 5 ale, pretoze to je aspon zaujimavy film a reziser" |
| 3 | dec2025 | Music | King of Pop (M. Jackson) | 2/5 | "uff, slaba. tuctova. ta uz musela byt na kvizoch milionkrat. ale aspon trochu zaujimava, takze 2/5. a zas zacina otazka 'who'." |
| 4 | mar12 | Geography | Christ statue + carnival, SE coast (Rio) | 3/5 | "3/5 (5 je najviac). zas otazka zacinajuca klasickym 'which', bez napadu, jednoducha, nekreativna. ale aspon trochu zaujimave" |
| 5 | mar12 | Geography | country shaped like umbrella (UK) | 4.5/5 | "dost zaujimava. zaujimava tym, ze si potrebujem predstavit tvar a rozmyslat ktora krajina by to mohla byt. ze to neni len klasicka 'which' otazka" |
| 6 | mar12 | Geography | opera house sail + SE coast + wildlife (Sydney) | 2.5/5 | "nic extra. tu budovu snad kazdy pozna. navyse pointa (sail-like) je doplnena dalsimi info... to moc nedava zmysel doplnat hlavnu pointu dalsimi. bud je pointa dostatocna ale neni dobra. videl som to uz 2-3krat pri hodnoteni." |
| 7 | mar19 v2_cot | Movies | Jaws dun-dun, how many notes? (Two) | 4.5/5 fact, answer leaked | "neviem odpoved, aj ked mam pocit ze otazka to tak navrhuje (two-note). inak velmi zaujimava. ak ta odpoved 2 neni 'leaknuta' v otazke, tak 4.5 z 5" |
| 8 | mar19 v2_cot | Movies | Wilhelm Scream, what happened? (alligator) | 5/5 | "to je mega zaujimave. 5/5. ked otazky zacinaju 'which/who/what' atd, neber to ako pravidlo ze vzdy je to zle. len treba dat vacsi pozor pri takychto otazkach" |
| 9 | mar19 v2_cot | Logic | 3L & 5L jug, measure 4L | good Q, format problem | "otazka je dobra, ale problem s odpovedou — odpoved bola dlha a pri hodnoteni uzivatelovej odpovede je tazke pre llm vyhodnotit ten logicky postup, ktory moze byt rozny, mat odchylky a nedostatky." |
| 10 | may4 | Marvel | which came first: BP hero vs party | 3/5 | "pre fanusikov marvel asi fajn, pre mna nezaujimave. taketo otazky by nemali byt moc v general knowledge, ale v kategoriach. otazka tak 3/5. je to len ohladne roku, ale mozno pre fanusikov zaujimave." |
| 11 | may4 | Harry Potter | Dumbledore = Old English for? (bumblebee) | 5/5 | "super otazka. 5/5. nikdy som sa nad tym nezamyslel ze by to mohlo nieco znamenat, takze pre mna prekvapive a som rad ze som sa to dozvedel. ale harry pottera mam rad, takze subjektivnejsie" |
| 12 | may4 | Football | T/F Arsenal Invincibles 49 games | 5/5 | "parada. nesledujem futbal, ale pride mi to velmi zaujimava. 5/5. mala vyhrada k formatu — ak je true/false, tak by sa otazka mala renderovat ako MCQ" |
| 13 | may19 NEWEST | Language&History | 'mile' = thousand what? (Roman paces) | 5/5 | "velmi zaujimave. 5/5. mozno jednoducha pre inych, ale pre mna zaujimava a zabavna. skor to je asi taky fun fact nez tvrdy fakt z wiki." |
| 14 | may19 NEWEST | Curling | sweeping melts ice, moves stone (True) | 4/5 | "super, aj ked velmi jednoduche. 4/5. zaujimavy fakt ale" |
| 15 | may19 NEWEST | Hockey | Stanley Cup 1-day ritual (True) | ~4/5, telegraphed | "super, velmi zaujimave. len je ta otazka tak podana, ze z toho vcelku vyplyva ze odpoved je true." |
| 16 | may19 NEWEST | Business | LEGO biggest tyre maker, how many? (300M) | 5/5 | "super otazka. zabavna. 5/5. mozno stoji za zvazenie dat ju ako MCQ, pretoze odhadnut 300 mil je narocne... viac sa mi pozdava MCQ." |

### Round 2 (Q17–36, English)

| # | wave | topic | question (short) | rating | founder reason (verbatim) |
|---|------|-------|------------------|--------|---------------------------|
| 17 | dec2025 | Science | element named after periodic-table creator (Mendelevium) | 2/5 | "quite basic. nothing surprising. very common quiz question. and boring. very factual." |
| 18 | dec2025 | Science | proportionally strongest muscle (masseter) | 4/5 | "very interesting in my opinion. a bit unexpected for me. had to think a little." |
| 19 | dec2025 | GenKnow | board game banned in USSR (Monopoly) | unrated | "interesting. maybe worth keeping. not gonna rate as i've seen this question too many times." |
| 20 | mar12 | Geography (image) | listed props → gladiator amphitheater, boot peninsula, Tiber (Rome) | 1/5 | "boring. and as mentioned before, it doesn't make sense to list properties of something. either there's one point that is satisfactory or the question doesn't make sense." |
| 21 | mar12 | Geography (image) | country like two dancing islands (New Zealand) | 4/5 | "interesting. it forces me to use my imagination and even though i don't know which country it is, i still think i have a chance to guess compared to those fact-based boring questions." |
| 22 | mar19 v2_cot | Geography | nearest humans to Point Nemo (ISS astronauts) | 5/5+ | "wow. 5/5 and even more. super interesting fact. unexpected answer. very interesting topic." |
| 23 | mar19 v2_cot | Sports | 1904 marathon DQ (rode a car 11 miles) | ~4/5 w/ caveat | "quite interesting. would be probably 4/5 but i'm doubtful about the answer — is the fact about 11 miles critical, or is saying 'driving' enough? careful about these ambiguous answers. answers need to be very unambiguous." |
| 24 | mar19 v2_cot | Food | ketchup prescribed for what? (liver/indigestion/diarrhea) | 4/5 | "quite interesting, 4/5. i like it. unexpected that it was used for medical purposes." |
| 25 | may4 | Disney | Lion King Zulu chant meaning (here comes a lion) | 5/5 | "very good and interesting, 5/5. not a basic fact. interesting topic." |
| 26 | may4 | Disney | T/F Walt Disney voiced Mickey ~20yrs (True) | 4/5 | "very interesting and fun fact. 4/5 as the question suggests answer would be true. it seems like all of the true/false questions are true but i might be wrong." |
| 27 | may4 | Disney | which came first: Pinocchio film vs novel (novel) | 3.5/5 | "well usually books come before films, so not that surprising. but still quite interesting and good to know this. 3,5/5 maybe?" |
| 28 | may4 | Harry Potter | Hogwarts motto translation (never tickle a sleeping dragon) | 5/5 | "5/5. but i like harry potter. and it's possible to deduct the answer from that phrase." |
| 29 | may19 NEWEST | History | Napoleon myth, which country's cartoonists? (Britain) | 4/5 | "the question seems to reveal the answer — 'came from British wartime propaganda'. otherwise very interesting. 4/5 let's say" |
| 30 | may19 NEWEST | Materials | spider-silk net could stop what? (jumbo jet) | interesting, broken answer | "very interesting question, but it's hard to guess the answer. anything can weigh as much as a jumbo jet. so the answer should be rethought and/or the question formatted differently. maybe it could be a mcq... there seem to be more of this problem in multiple questions so it should be tackled more systematically." |
| 31 | may19 NEWEST | Astronomy | how fast Moon drifts away? (3.8 cm/yr) | 5/5 | "5/5. super interesting but again would be probably more fun to answer with multiple choices." |
| 32 | may19 NEWEST | Baseball | Cy Young career wins within 25 (511) | ~3/5 (can't judge) | "can't rate as i don't even know what sport it is. i'm not a sports fan... but still a bit interesting fact. if i had to rate, then 3/5" |
| 33 | may19 NEWEST | Biology | mantis shrimp flash phenomenon (cavitation) | 5/5 | "wow. 5/5. super interesting." |
| 34 | may19 NEWEST | History | Cleopatra closer to: pyramids or Moon landings? (Moon) | 5/5 | "wow, super interesting. 5/5" |
| 35 | may19 NEWEST | Food Science | what's special about cocoa butter melting point? | 2/5 | "not sure the answer is logically correct. or in fact, it does melt in hands as well. it's a weirdly formatted question and hard to see the point. 2/5?" |
| 36 | may19 NEWEST | Golf | St Andrews 22→18 holes, T/F (True) | interesting fact, bad format | "again, interesting but i'd just guess 'true'. the whole question/answer pair should be better formulated, differently. the fact itself is fun and interesting. maybe the question should be how many holes there were before 18. but that's just a suggestion." |

**Verified finding:** T/F answer bias — of 34 true/false questions in the corpus, **32 are TRUE, 2 FALSE (94%)**. Founder spotted this from 2 samples (Q26). → high-priority pipeline fix.

**Wave averages (rated only):** wave1 3.00 · wave2 3.00 · wave3 (v2_cot) **4.50** · wave4 4.36 · wave5 (newest) 4.20. Quality peaked at the March v2_cot wave.
