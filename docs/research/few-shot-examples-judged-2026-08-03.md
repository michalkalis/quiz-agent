# Few-shot príklady prehnané sudcami pipeline (2026-08-03)

Každý z 46 príkladov (32 gold + 14 opravených z kontrastných párov) prešiel presne tou istou skórovacou bránou ako generované otázky: **2 sudcovia (gpt-5.6 + gemini-3.1-pro) × 7 dimenzií, každá dimenzia samostatné volanie** — plus 4 deterministické formátové kontroly (leak odpovede, dĺžka odpovede, imperiálne jednotky, nedatovaný rekord). Škála 1–10; produkčná brána vyhadzuje pri priemere pod 3,0 (je zámerne mierna — odstraňuje pokazené, nie priemerné).

**Súhrn:** pod bránou (priemer < 3,0): **0** · s formátovým flagom: **6** · aspoň jedna dimenzia ≤ 4: **23**.


## Rebríček (najhoršie hore)

| # | Zdroj | Tvoje | Otázka | Priemer | Slabé dimenzie (≤4) | Formátové flagy |
|---|---|---|---|---|---|---|
| 1 | gold | 8/10 | Which Olympic sport was once judged partly on the elegance of a competitor's dive into the… | **3.64** | Prekvapenie 1.5, Prerozprávateľnosť 2.0, Remeselné podanie 2.0, Rozprúdi debatu 3.5, Faktická istota 4.0 | — |
| 2 | gold | 8/10 | In ancient Egypt, butchers wore a specific garment to keep blood off their clothes. What w… | **4.93** | Prerozprávateľnosť 2.5, Prekvapenie 2.5, Remeselné podanie 2.5 | — |
| 3 | gold | 8/10 | What percentage of the human body is made up of water: closer to 30%, 60%, or 90%? | **5.71** | Prekvapenie 2.5, Prerozprávateľnosť 3.0, Remeselné podanie 3.0 | — |
| 4 | gold | 8/10 | There are more possible iterations of a game of chess than there are atoms in the observab… | **5.79** | Cesta k odpovedi 3.0, Remeselné podanie 3.5, Prekvapenie 4.0 | pridlhá odpoveď |
| 5 | gold | 8/10 | In what year did the first message cross the ARPANET, the prototype of the modern internet… | **5.79** | Prekvapenie 3.0, Remeselné podanie 3.0 | — |
| 6 | fixed-pair | — | Which drug do most adults on Earth take every single morning, entirely legally, often befo… | **5.79** | Prerozprávateľnosť 3.5 | — |
| 7 | gold | 8/10 | Which of these is NOT a real element on the periodic table: Einsteinium, Kryptonite, Calif… | **5.86** | Rozprúdi debatu 4.0, Prekvapenie 4.0 | — |
| 8 | gold | 9/10 | What word in the English language is always spelled incorrectly? | **5.93** | Prekvapenie 2.5, Remeselné podanie 2.5 | leak odpovede v zadaní |
| 9 | fixed-pair | — | For over a century, light-bulb filaments glowed white-hot without melting thanks to the me… | **6.0** | Prekvapenie 2.5, Cesta k odpovedi 4.0 | — |
| 10 | gold | 9/10 | What five-letter English word becomes shorter when you add two letters to it? | **6.36** | Remeselné podanie 2.5, Prekvapenie 3.0 | — |
| 11 | fixed-pair | — | The hottest planet in our Solar System is NOT the one closest to the Sun. Which planet hol… | **6.36** | Prekvapenie 3.5, Rozprúdi debatu 4.0 | nedatovaný rekord |
| 12 | fixed-pair | — | Which is bigger: a shrimp's heart or its brain? | **6.36** | Cesta k odpovedi 3.5 | leak odpovede v zadaní |
| 13 | gold | 9/10 | Humans share about 60% of their genes with a common fruit. What is it? | **6.5** | Prekvapenie 3.5, Cesta k odpovedi 4.0 | — |
| 14 | gold | 10/10 | Ketchup was sold in the 1830s as a cure for which common ailment? | **6.79** | Cesta k odpovedi 3.0, Remeselné podanie 4.0 | — |
| 15 | fixed-pair | — | The world's first electric traffic light was switched on the same year a war broke out tha… | **6.86** | — | leak odpovede v zadaní |
| 16 | gold | 9/10 | The world's oldest known recipe, found on a 4,000-year-old Sumerian tablet, is for which t… | **6.93** | — | — |
| 17 | gold | 8/10 | One planet in our solar system has a perfect hexagon-shaped storm at its north pole. Name … | **6.93** | Cesta k odpovedi 3.5 | — |
| 18 | fixed-pair | — | What color are flamingos when they hatch — before their diet kicks in? | **6.93** | — | — |
| 19 | fixed-pair | — | In the 1880s, an American pharmacist invented a 'nerve tonic' that today outsells every ot… | **6.93** | Prekvapenie 4.0 | — |
| 20 | gold | 8/10 | Which animal's fingerprints are virtually indistinguishable from human fingerprints, even … | **7.0** | Cesta k odpovedi 2.5 | — |
| 21 | gold | 9/10 | A bat and a ball cost $1.10 together. The bat costs $1.00 more than the ball. How much doe… | **7.0** | Prekvapenie 4.0 | — |
| 22 | gold | 9/10 | Which country has the most pyramids? | **7.08** | Remeselné podanie 3.0 | — |
| 23 | gold | 9/10 | Oxford University is older than which ancient empire? | **7.14** | Cesta k odpovedi 4.0 | — |
| 24 | gold | 9/10 | Which country consumes the most coffee per person: Brazil, the United States, or Finland? | **7.21** | Remeselné podanie 3.0 | — |
| 25 | fixed-pair | — | Which capital city exists only because Sydney and Melbourne couldn't stand the idea of the… | **7.21** | — | — |
| 26 | fixed-pair | — | The USA celebrates its birthday on the 4th of July — yet most founding fathers actually si… | **7.21** | — | — |
| 27 | fixed-pair | — | In Shakespeare's original Romeo and Juliet, how old was Juliet — an age that would horrify… | **7.29** | — | — |
| 28 | fixed-pair | — | A newborn baby has about 270 bones, an adult only 206. What happened to the rest? | **7.29** | Prekvapenie 4.0 | — |
| 29 | gold | 8/10 | In a room of just 23 people, what is the probability that two share a birthday: about 10%,… | **7.57** | — | — |
| 30 | gold | 9/10 | What everyday material connects a pencil, a tennis racket, and a diamond? | **7.64** | — | — |
| 31 | gold | 9/10 | If all the world's ice melted, would sea levels rise by about 2 meters, 20 meters, or 70 m… | **7.64** | — | — |
| 32 | gold | 8/10 | Bubble wrap was originally invented and marketed as what kind of home product? | **7.71** | — | — |
| 33 | gold | 8/10 | Which country has more pyramids than Egypt? | **7.79** | — | — |
| 34 | gold | 9/10 | True or false: Cleopatra lived closer in time to the Moon landing than to the building of … | **7.79** | Remeselné podanie 3.0 | — |
| 35 | fixed-pair | — | All of Earth's land — every continent and every island — could fit inside one ocean with r… | **7.86** | — | — |
| 36 | gold | 9/10 | Which spice was so prized the Dutch traded Manhattan for a tiny Indonesian island to contr… | **7.93** | — | — |
| 37 | gold | 9/10 | How many trees are there on Earth: closer to 400 million, 40 billion, or 3 trillion? | **8.0** | — | — |
| 38 | gold | 8/10 | Mars is red, but what colour is a Martian sunset? | **8.07** | — | — |
| 39 | fixed-pair | — | Every atom of iron in your blood was forged in the same distant place. Where? | **8.07** | — | — |
| 40 | gold | 8/10 | Thanks to its overseas territories, one country spans 12 time zones — more than any other.… | **8.14** | — | — |
| 41 | gold | 9/10 | Which is heavier: all the ants on Earth, or all the humans? | **8.36** | — | — |
| 42 | fixed-pair | — | Australian police once worried that crime scenes could be contaminated by the fingerprints… | **8.36** | — | — |
| 43 | gold | 9/10 | If you drove your car straight up at highway speed, how long would it take to reach space:… | **8.5** | — | — |
| 44 | gold | 9/10 | If you shuffled a deck of cards perfectly randomly, what are the chances that exact arrang… | **8.5** | — | — |
| 45 | gold | 9/10 | If you fold a standard piece of paper in half 42 times (if you could), how far would it re… | **8.57** | — | — |
| 46 | gold | 9/10 | Was Cleopatra closer in time to the building of the Great Pyramid or to the Moon landing? | **8.86** | — | leak odpovede v zadaní |

## Detaily (zoradené od najhoršieho)

<details><summary><b>1. [3.64] gold-6</b> — Surprising Connection · sports, tvoje hodnotenie 8/10</summary>

**Q:** Which Olympic sport was once judged partly on the elegance of a competitor's dive into the water during the swimming events?

**A:** Diving

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **1.5** | 2.0 | 1.0 |
| Prerozprávateľnosť | **2.0** | 3.0 | 1.0 |
| Remeselné podanie | **2.0** | 2.0 | 2.0 |
| Rozprúdi debatu | **3.5** | 3.0 | 4.0 |
| Faktická istota | **4.0** | 7.0 | 1.0 |
| Cesta k odpovedi | **6.0** | 8.0 | 4.0 |
| Vhodnosť za volant | **6.5** | 8.0 | 5.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* The answer is heavily telegraphed by “dive into the water,” so there is little surprising reveal or aha moment.
- **Prekvapenie:** *gemini-3.1-pro-preview:* Using the word 'dive' in the prompt to cue the answer 'Diving' completely eliminates any potential for surprise or an 'aha!' moment.
- **Prerozprávateľnosť:** *gpt-5.6-sol:* The historical judging detail is mildly curious, but the answer feels obvious and the fact lacks a memorable twist.
- **Prerozprávateľnosť:** *gemini-3.1-pro-preview:* The fact is either confusingly phrased or simply states the obvious definition of the sport, leaving absolutely nothing interesting or surprising to share with others.
- **Remeselné podanie:** *gpt-5.6-sol:* The stem directly leaks “Diving” through the word “dive,” making the answer trivial rather than cleverly framed.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* The word 'dive' in the stem directly leaks the answer 'Diving', triggering the stem answer-leak penalty.
- **Rozprúdi debatu:** *gpt-5.6-sol:* The wording strongly telegraphs “diving,” leaving little room for competing guesses or discussion.
- **Rozprúdi debatu:** *gemini-3.1-pro-preview:* The slightly confusing phrasing might prompt a few tentative guesses like synchronized swimming or water polo, but the seemingly tautological answer won't generate deep debate or stories.
- **Faktická istota:** *gpt-5.6-sol:* Diving is the likely intended answer, though it remains judged on execution and elegance today, making the historical wording somewhat imprecise.
- **Faktická istota:** *gemini-3.1-pro-preview:* The question's premise is factually nonsensical, as diving is its own separate event judged entirely on the dive, not 'partly' during 'swimming events'.

</details>

<details><summary><b>2. [4.93] gold-3</b> — Surprising Connection · history, tvoje hodnotenie 8/10</summary>

**Q:** In ancient Egypt, butchers wore a specific garment to keep blood off their clothes. What was it?

**A:** The apron

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prerozprávateľnosť | **2.5** | 4.0 | 1.0 |
| Prekvapenie | **2.5** | 3.0 | 2.0 |
| Remeselné podanie | **2.5** | 3.0 | 2.0 |
| Rozprúdi debatu | **4.5** | 4.0 | 5.0 |
| Faktická istota | **5.5** | 5.0 | 6.0 |
| Cesta k odpovedi | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prerozprávateľnosť:** *gpt-5.6-sol:* The ancient-Egypt setting adds mild interest, but the unsurprising answer makes the fact unlikely to be retold.
- **Prerozprávateľnosť:** *gemini-3.1-pro-preview:* Wearing an apron to keep blood off clothes is a completely mundane, expected practice for a butcher in any era, offering zero surprise or novelty to retell.
- **Prekvapenie:** *gpt-5.6-sol:* The answer is intuitive from the garment’s function, offering little unexpected reveal beyond its ancient use.
- **Prekvapenie:** *gemini-3.1-pro-preview:* The answer is entirely mundane and expected, offering no twist or 'aha!' moment since butchers wearing aprons is a universally known, everyday concept rather than a surprising historical reveal.
- **Remeselné podanie:** *gpt-5.6-sol:* The historical setup adds flavor, but the garment’s function makes “apron” trivially deducible with no ancient-Egypt knowledge.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* The framing is a deductive giveaway because any player can easily guess 'apron' from the universal function of a butcher's garment, rendering the ancient Egyptian context completely irrelevant.

</details>

<details><summary><b>3. [5.71] gold-24</b> — Estimation Challenge · science, tvoje hodnotenie 8/10</summary>

**Q:** What percentage of the human body is made up of water: closer to 30%, 60%, or 90%?

**A:** About 60%

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **2.5** | 3.0 | 2.0 |
| Prerozprávateľnosť | **3.0** | 4.0 | 2.0 |
| Remeselné podanie | **3.0** | 3.0 | 3.0 |
| Rozprúdi debatu | **5.0** | 5.0 | 5.0 |
| Cesta k odpovedi | **7.5** | 8.0 | 7.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* The roughly 60% water figure is a familiar, frequently repeated human-body fact, so it offers little surprise or revelation.
- **Prekvapenie:** *gemini-3.1-pro-preview:* The fact that the human body is roughly 60% water is an extremely common, overexposed trivia staple taught in basic science classes worldwide, offering no real 'aha!' moment.
- **Prerozprávateľnosť:** *gpt-5.6-sol:* The 60% water fact is familiar and mildly interesting, but not surprising enough to retell.
- **Prerozprávateľnosť:** *gemini-3.1-pro-preview:* This is a widely known, basic science fact that lacks the surprise or novelty required to prompt someone to share it with a friend.
- **Remeselné podanie:** *gpt-5.6-sol:* The three-option estimate is clear and playable, but it is still a bare factual recall question with little inventive framing.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* The question is a bare first-degree recall of a basic fact with multiple-choice options, lacking any clever framing or deductive angle, which caps its score at 3.

</details>

<details><summary><b>4. [5.79] gold-21</b> — Scale Surprise · science, tvoje hodnotenie 8/10</summary>

**Q:** There are more possible iterations of a game of chess than there are atoms in the observable universe. Approximately how many possible chess games are there?

**A:** About 10 to the power of 120

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **3.0** | 4.0 | 2.0 |
| Remeselné podanie | **3.5** | 5.0 | 2.0 |
| Prekvapenie | **4.0** | 6.0 | 2.0 |
| Vhodnosť za volant | **5.5** | 7.0 | 4.0 |
| Rozprúdi debatu | **7.0** | 7.0 | 7.0 |
| Prerozprávateľnosť | **8.0** | 8.0 | 8.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 7 | | |

**Formátové flagy:** pridlhá odpoveď: long_answer(7w)


**Prečo slabé dimenzie (sudcovia):**

- **Cesta k odpovedi:** *gpt-5.6-sol:* A chess-savvy player could estimate from branching moves and game length, but the exact 10^120 scale is mostly a recalled fact.
- **Cesta k odpovedi:** *gemini-3.1-pro-preview:* Without multiple-choice options, players cannot logically deduce or estimate the exact exponent of 10^120, making this a pure recall question or a virtually impossible blind guess.
- **Remeselné podanie:** *gpt-5.6-sol:* The atoms-in-the-universe comparison adds a memorable hook, but the question still largely tests recall of a famous numerical estimate.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* The question relies on bare first-degree recall of a highly specific and obscure number, capping its framing score at 3.
- **Prekvapenie:** *gpt-5.6-sol:* The staggering 10^120 figure has real wow factor, though the question already telegraphs the core surprise and the chess-versus-atoms comparison is fairly familiar trivia.
- **Prekvapenie:** *gemini-3.1-pro-preview:* The mind-blowing fact is completely given away in the setup, leaving the actual answer to be a dry, unguessable exponent that offers no 'aha!' moment.

</details>

<details><summary><b>5. [5.79] gold-32</b> — year_guess · technology, tvoje hodnotenie 8/10</summary>

**Q:** In what year did the first message cross the ARPANET, the prototype of the modern internet?

**Možnosti:** A) 1959 · B) 1969 · C) 1979 · D) 1989

**A:** b

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **3.0** | 4.0 | 2.0 |
| Remeselné podanie | **3.0** | 3.0 | 3.0 |
| Rozprúdi debatu | **4.5** | 5.0 | 4.0 |
| Prerozprávateľnosť | **5.0** | 5.0 | 5.0 |
| Cesta k odpovedi | **6.5** | 7.0 | 6.0 |
| Vhodnosť za volant | **8.5** | 9.0 | 8.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |
| Kvalita distraktorov (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* The 1969 date may be mildly interesting, but it is a standard technology-history fact with little twist or revelatory payoff.
- **Prekvapenie:** *gemini-3.1-pro-preview:* Asking for the specific year of a historical event is a standard single-fact lookup that tests rote memory rather than delivering a perspective-shifting 'aha!' moment.
- **Remeselné podanie:** *gpt-5.6-sol:* This is a clear but bare first-degree date-recall question with no distinctive framing or deduction.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* Asking for the specific year an event occurred is bare first-degree recall, which caps this dimension at 3.

</details>

<details><summary><b>6. [5.79] fixed-11</b> — FIXED anti-pattern · General</summary>

**Q:** Which drug do most adults on Earth take every single morning, entirely legally, often before they've said a word to anyone?

**A:** Caffeine

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prerozprávateľnosť | **3.5** | 5.0 | 2.0 |
| Prekvapenie | **4.5** | 6.0 | 3.0 |
| Rozprúdi debatu | **5.5** | 7.0 | 4.0 |
| Remeselné podanie | **5.5** | 3.0 | 8.0 |
| Vhodnosť za volant | **6.0** | 6.0 | 6.0 |
| Faktická istota | **7.5** | 5.0 | 10.0 |
| Cesta k odpovedi | **8.0** | 8.0 | 8.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prerozprávateľnosť:** *gpt-5.6-sol:* Calling morning caffeine a legal drug is mildly amusing, but the framing is familiar and not especially memorable.
- **Prerozprávateľnosť:** *gemini-3.1-pro-preview:* The fact that caffeine is a daily, legal drug is a well-worn trope rather than a surprising piece of new trivia, giving it almost no retelling value.

</details>

<details><summary><b>7. [5.86] gold-29</b> — Odd One Out · science, tvoje hodnotenie 8/10</summary>

**Q:** Which of these is NOT a real element on the periodic table: Einsteinium, Kryptonite, Californium, or Oganesson?

**A:** Kryptonite

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Rozprúdi debatu | **4.0** | 5.0 | 3.0 |
| Prekvapenie | **4.0** | 5.0 | 3.0 |
| Prerozprávateľnosť | **4.5** | 6.0 | 3.0 |
| Remeselné podanie | **5.0** | 5.0 | 5.0 |
| Vhodnosť za volant | **5.5** | 7.0 | 4.0 |
| Cesta k odpovedi | **8.0** | 8.0 | 8.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Rozprúdi debatu:** *gpt-5.6-sol:* The mix of obscure real elements and a famous fictional substance may prompt brief guessing, but Kryptonite is likely an obvious choice.
- **Rozprúdi debatu:** *gemini-3.1-pro-preview:* Once a player recognizes Kryptonite as the famous fictional rock from Superman, any potential debate instantly ends.
- **Prekvapenie:** *gpt-5.6-sol:* The contrast between fictional Kryptonite and three unusually named real elements offers a mild aha, but the Superman reference and odd-one-out format are familiar.
- **Prekvapenie:** *gemini-3.1-pro-preview:* While the reality of silly-sounding elements like Einsteinium is mildly amusing, identifying Kryptonite as fictional is a widely known pop-culture staple rather than a genuine 'aha!' moment.

</details>

<details><summary><b>8. [5.93] gold-14</b> — Wordplay Revelation · language, tvoje hodnotenie 9/10</summary>

**Q:** What word in the English language is always spelled incorrectly?

**A:** Incorrectly

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **2.5** | 3.0 | 2.0 |
| Remeselné podanie | **2.5** | 3.0 | 2.0 |
| Rozprúdi debatu | **4.5** | 4.0 | 5.0 |
| Prerozprávateľnosť | **5.5** | 6.0 | 5.0 |
| Cesta k odpovedi | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Formátové flagy:** leak odpovede v zadaní: stem_leak(incorrectly)


**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* The wordplay can produce a quick aha for non-native speakers, but it is an extremely familiar and overused riddle.
- **Prekvapenie:** *gemini-3.1-pro-preview:* This is a classic, highly overexposed riddle rather than a surprising trivia fact, making it more likely to elicit a groan than a genuine 'aha!' moment.
- **Remeselné podanie:** *gpt-5.6-sol:* It is a classic wordplay riddle, but the answer appears verbatim in the stem, making it a stem-answer leak.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* This is a classic wordplay riddle rather than a trivia question, triggering the deductive giveaway and stem answer-leak caps since the exact answer is spoken in the prompt and requires zero outside knowledge.

</details>

<details><summary><b>9. [6.0] fixed-5</b> — FIXED anti-pattern · General</summary>

**Q:** For over a century, light-bulb filaments glowed white-hot without melting thanks to the metal with the highest melting point of them all. Which metal?

**A:** Tungsten

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **2.5** | 3.0 | 2.0 |
| Cesta k odpovedi | **4.0** | 4.0 | 4.0 |
| Rozprúdi debatu | **4.5** | 6.0 | 3.0 |
| Prerozprávateľnosť | **5.5** | 6.0 | 5.0 |
| Remeselné podanie | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **8.0** | 8.0 | 8.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* Tungsten’s use in light-bulb filaments and its very high melting point are familiar textbook facts, so the reveal offers little surprise.
- **Prekvapenie:** *gemini-3.1-pro-preview:* Identifying tungsten by its well-known use in lightbulbs is a standard, single-fact lookup that lacks any twist or 'aha!' moment.
- **Cesta k odpovedi:** *gpt-5.6-sol:* The filament and extreme-heat clues narrow it to a metal, but identifying tungsten still depends mostly on recalled knowledge rather than deduction.
- **Cesta k odpovedi:** *gemini-3.1-pro-preview:* The prompt provides two strong contextual clues (light bulbs and highest melting point) to trigger recall, but the player cannot logically deduce or estimate the specific metal if they lack the factual knowledge.

</details>

<details><summary><b>10. [6.36] gold-12</b> — Wordplay Revelation · language, tvoje hodnotenie 9/10</summary>

**Q:** What five-letter English word becomes shorter when you add two letters to it?

**A:** Short

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Remeselné podanie | **2.5** | 3.0 | 2.0 |
| Prekvapenie | **3.0** | 3.0 | 3.0 |
| Prerozprávateľnosť | **6.0** | 6.0 | 6.0 |
| Rozprúdi debatu | **6.5** | 6.0 | 7.0 |
| Cesta k odpovedi | **8.0** | 8.0 | 8.0 |
| Vhodnosť za volant | **8.5** | 8.0 | 9.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Remeselné podanie:** *gpt-5.6-sol:* The wordplay is neat, but “shorter” visibly contains the answer “short,” making the stem itself an answer-leak.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* This is a classic wordplay riddle rather than a trivia question, and it suffers from a direct stem answer-leak because the word 'shorter' trivially gives away the root word 'short'.
- **Prekvapenie:** *gpt-5.6-sol:* The wordplay can produce a quick aha for non-native speakers, but this is a very familiar and overused classic riddle.
- **Prekvapenie:** *gemini-3.1-pro-preview:* Although the wordplay provides a mild 'aha!' moment, this is a highly overexposed classic riddle rather than a genuinely surprising trivia fact.

</details>

<details><summary><b>11. [6.36] fixed-9</b> — FIXED anti-pattern · General</summary>

**Q:** The hottest planet in our Solar System is NOT the one closest to the Sun. Which planet holds the record?

**A:** Venus

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **3.5** | 4.0 | 3.0 |
| Rozprúdi debatu | **4.0** | 4.0 | 4.0 |
| Remeselné podanie | **5.5** | 6.0 | 5.0 |
| Prerozprávateľnosť | **6.0** | 6.0 | 6.0 |
| Cesta k odpovedi | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **8.0** | 9.0 | 7.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Formátové flagy:** nedatovaný rekord: undated_record(record)


**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* The Mercury-versus-Venus twist offers a small aha, but it is a very common school-science and trivia fact.
- **Prekvapenie:** *gemini-3.1-pro-preview:* While the question subverts the logical assumption that the closest planet is the hottest, this specific fact is a well-worn trivia staple that lacks a genuine 'aha!' moment.
- **Rozprúdi debatu:** *gpt-5.6-sol:* The Mercury-versus-Venus twist may prompt a brief guess, but it is mostly a straightforward fact with little room for debate or stories.
- **Rozprúdi debatu:** *gemini-3.1-pro-preview:* By explicitly eliminating the most obvious answer, it prompts a brief moment of deduction and a couple of alternate planetary guesses, but it won't spark prolonged debate or storytelling.

</details>

<details><summary><b>12. [6.36] fixed-13</b> — FIXED anti-pattern · General</summary>

**Q:** Which is bigger: a shrimp's heart or its brain?

**A:** Its heart

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **3.5** | 3.0 | 4.0 |
| Prekvapenie | **5.0** | 6.0 | 4.0 |
| Rozprúdi debatu | **5.5** | 5.0 | 6.0 |
| Prerozprávateľnosť | **6.0** | 7.0 | 5.0 |
| Remeselné podanie | **6.0** | 7.0 | 5.0 |
| Faktická istota | **8.5** | 7.0 | 10.0 |
| Vhodnosť za volant | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Formátové flagy:** leak odpovede v zadaní: stem_leak(heart)


**Prečo slabé dimenzie (sudcovia):**

- **Cesta k odpovedi:** *gpt-5.6-sol:* Without specific shrimp anatomy knowledge, the player has little basis to deduce the answer beyond a coin flip.
- **Cesta k odpovedi:** *gemini-3.1-pro-preview:* While players can use basic biological intuition that a simple crustacean has a tiny brain, the binary format ultimately reduces the engagement path to a 50/50 coin flip.

</details>

<details><summary><b>13. [6.5] gold-4</b> — Surprising Connection · science, tvoje hodnotenie 9/10</summary>

**Q:** Humans share about 60% of their genes with a common fruit. What is it?

**A:** Banana

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **3.5** | 4.0 | 3.0 |
| Cesta k odpovedi | **4.0** | 4.0 | 4.0 |
| Remeselné podanie | **4.5** | 6.0 | 3.0 |
| Rozprúdi debatu | **7.0** | 7.0 | 7.0 |
| Prerozprávateľnosť | **8.0** | 8.0 | 8.0 |
| Faktická istota | **9.0** | 8.0 | 10.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* The human–banana genetic similarity is mildly amusing and counterintuitive, but it is a widely circulated trivia fact.
- **Prekvapenie:** *gemini-3.1-pro-preview:* While the genetic similarity between humans and bananas is inherently amusing, it is a highly overexposed pop-science staple that has appeared in countless trivia games, diminishing its surprise factor.
- **Cesta k odpovedi:** *gpt-5.6-sol:* The fruit category permits a broad guess, but identifying banana mainly depends on recalling this common science fact rather than deduction.
- **Cesta k odpovedi:** *gemini-3.1-pro-preview:* There is no logical path to deduce the exact fruit based on genetics, but explicitly naming the category ('common fruit') narrows the answer down to a few highly guessable options.

</details>

<details><summary><b>14. [6.79] gold-5</b> — Surprising Connection · food, tvoje hodnotenie 10/10</summary>

**Q:** Ketchup was sold in the 1830s as a cure for which common ailment?

**A:** Diarrhea

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **3.0** | 3.0 | 3.0 |
| Remeselné podanie | **4.0** | 5.0 | 3.0 |
| Rozprúdi debatu | **7.5** | 7.0 | 8.0 |
| Faktická istota | **7.5** | 7.0 | 8.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Cesta k odpovedi:** *gpt-5.6-sol:* Players might infer a digestive complaint from ketchup, but cannot reasonably narrow it to diarrhea without recalling the historical fact.
- **Cesta k odpovedi:** *gemini-3.1-pro-preview:* While players might guess stomach-related issues since ketchup is ingested, pinpointing 'diarrhea' specifically relies on pure trivia recall rather than logical deduction.
- **Remeselné podanie:** *gpt-5.6-sol:* The surprising ketchup-as-medicine premise provides a memorable hook, though the question remains a straightforward historical-fact recall.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* While the historical fact is interesting, the framing is a bare first-degree recall question without any clever deductive angles, capping its score.

</details>

<details><summary><b>15. [6.86] fixed-8</b> — FIXED anti-pattern · General</summary>

**Q:** The world's first electric traffic light was switched on the same year a war broke out that would change everything. Which war?

**A:** World War I

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Rozprúdi debatu | **5.5** | 4.0 | 7.0 |
| Vhodnosť za volant | **6.0** | 7.0 | 5.0 |
| Prerozprávateľnosť | **6.5** | 6.0 | 7.0 |
| Prekvapenie | **6.5** | 6.0 | 7.0 |
| Cesta k odpovedi | **7.0** | 6.0 | 8.0 |
| Remeselné podanie | **7.5** | 7.0 | 8.0 |
| Faktická istota | **9.0** | 8.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Formátové flagy:** leak odpovede v zadaní: stem_leak(war)


</details>

<details><summary><b>16. [6.93] gold-7</b> — Surprising Connection · history, tvoje hodnotenie 9/10</summary>

**Q:** The world's oldest known recipe, found on a 4,000-year-old Sumerian tablet, is for which type of product?

**A:** Beer

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **4.5** | 4.0 | 5.0 |
| Remeselné podanie | **5.5** | 5.0 | 6.0 |
| Prekvapenie | **6.5** | 6.0 | 7.0 |
| Rozprúdi debatu | **7.0** | 6.0 | 8.0 |
| Prerozprávateľnosť | **8.0** | 8.0 | 8.0 |
| Vhodnosť za volant | **8.0** | 8.0 | 8.0 |
| Faktická istota | **9.0** | 8.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>17. [6.93] gold-9</b> — Hidden Property · science, tvoje hodnotenie 8/10</summary>

**Q:** One planet in our solar system has a perfect hexagon-shaped storm at its north pole. Name it.

**A:** Saturn

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **3.5** | 3.0 | 4.0 |
| Remeselné podanie | **4.5** | 6.0 | 3.0 |
| Rozprúdi debatu | **5.5** | 6.0 | 5.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.0** | 8.0 | 8.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Cesta k odpovedi:** *gpt-5.6-sol:* The answer depends mainly on recalling Saturn’s famous hexagon, with only a weak deduction path toward stormy gas giants.
- **Cesta k odpovedi:** *gemini-3.1-pro-preview:* Players can easily narrow the options down to the gas giants, but identifying Saturn specifically relies entirely on factual recall rather than logical deduction.

</details>

<details><summary><b>18. [6.93] fixed-10</b> — FIXED anti-pattern · General</summary>

**Q:** What color are flamingos when they hatch — before their diet kicks in?

**A:** Grey

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **5.0** | 5.0 | 5.0 |
| Rozprúdi debatu | **6.5** | 6.0 | 7.0 |
| Remeselné podanie | **6.5** | 6.0 | 7.0 |
| Cesta k odpovedi | **6.5** | 6.0 | 7.0 |
| Prerozprávateľnosť | **7.0** | 7.0 | 7.0 |
| Faktická istota | **7.5** | 5.0 | 10.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>19. [6.93] fixed-14</b> — FIXED anti-pattern · General</summary>

**Q:** In the 1880s, an American pharmacist invented a 'nerve tonic' that today outsells every other drink on the planet. What is it?

**A:** Coca-Cola

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **4.0** | 5.0 | 3.0 |
| Rozprúdi debatu | **5.0** | 7.0 | 3.0 |
| Cesta k odpovedi | **7.0** | 6.0 | 8.0 |
| Prerozprávateľnosť | **7.5** | 8.0 | 7.0 |
| Remeselné podanie | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **8.5** | 8.0 | 9.0 |
| Faktická istota | **9.0** | 8.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* Coca-Cola’s medicinal origin offers a modest aha moment, though it is a fairly familiar piece of brand trivia.
- **Prekvapenie:** *gemini-3.1-pro-preview:* The origin of Coca-Cola as a pharmacist's medicinal tonic is a heavily overexposed trivia staple that offers little surprise, especially since the 'outsells every other drink' clue gives the answer away instantly.

</details>

<details><summary><b>20. [7.0] gold-8</b> — Hidden Property · nature, tvoje hodnotenie 8/10</summary>

**Q:** Which animal's fingerprints are virtually indistinguishable from human fingerprints, even under a microscope?

**A:** Koala

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **2.5** | 3.0 | 2.0 |
| Remeselné podanie | **5.5** | 6.0 | 5.0 |
| Rozprúdi debatu | **7.0** | 6.0 | 8.0 |
| Prekvapenie | **7.0** | 6.0 | 8.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.0** | 9.0 | 9.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Cesta k odpovedi:** *gpt-5.6-sol:* Without options, the animal category is too broad, and koala is mainly a surprising recalled fact rather than a deducible answer.
- **Cesta k odpovedi:** *gemini-3.1-pro-preview:* The player cannot logically deduce 'koala' over primates or other mammals with gripping hands; it relies entirely on recalling a specific, surprising piece of trivia.

</details>

<details><summary><b>21. [7.0] gold-27</b> — Lateral Thinking Puzzle · science, tvoje hodnotenie 9/10</summary>

**Q:** A bat and a ball cost $1.10 together. The bat costs $1.00 more than the ball. How much does the ball cost?

**A:** 5 cents

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **4.0** | 5.0 | 3.0 |
| Vhodnosť za volant | **4.5** | 7.0 | 2.0 |
| Remeselné podanie | **4.5** | 7.0 | 2.0 |
| Rozprúdi debatu | **8.0** | 7.0 | 9.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Cesta k odpovedi | **9.5** | 9.0 | 10.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* The intuitive 10-cent trap can produce a satisfying aha, but this classic puzzle is very widely known and often repeated.
- **Prekvapenie:** *gemini-3.1-pro-preview:* Although the counterintuitive answer provides a classic 'aha!' moment, this specific math riddle is one of the most overexposed trick questions in existence, severely limiting its surprise factor.

</details>

<details><summary><b>22. [7.08] gold-31</b> — comparison_bet_older_larger · geography, tvoje hodnotenie 9/10</summary>

**Q:** Which country has the most pyramids?

**Možnosti:** A) Egypt · B) Sudan · C) Mexico · D) Peru

**A:** b

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Remeselné podanie | **3.0** | 3.0 | 3.0 |
| Cesta k odpovedi | **5.0** | 4.0 | 6.0 |
| Faktická istota | **7.0** | 4.0 | 10.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Rozprúdi debatu | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |
| Kvalita distraktorov (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Remeselné podanie:** *gpt-5.6-sol:* It offers a mildly surprising misconception twist, but the stem is still bare first-degree recall with no crafted hook.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* The question relies on bare first-degree recall without any clever framing or deductive angle, capping its score at 3 despite the built-in misdirection away from Egypt.

</details>

<details><summary><b>23. [7.14] gold-18</b> — Scale Surprise · history, tvoje hodnotenie 9/10</summary>

**Q:** Oxford University is older than which ancient empire?

**A:** The Aztec Empire

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **4.0** | 2.0 | 6.0 |
| Faktická istota | **5.5** | 9.0 | 2.0 |
| Remeselné podanie | **6.5** | 6.0 | 7.0 |
| Rozprúdi debatu | **8.0** | 7.0 | 9.0 |
| Prekvapenie | **8.0** | 7.0 | 9.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Cesta k odpovedi:** *gpt-5.6-sol:* Without options, many empires could fit, so identifying the Aztec Empire depends almost entirely on recalling the specific trivia fact.
- **Cesta k odpovedi:** *gemini-3.1-pro-preview:* Players can use timeline reasoning to deduce it must be a famously 'newer' empire often mistaken for ancient, but without options, pinpointing the Aztecs over the Incas relies heavily on recalling a specific viral trivia trope.

</details>

<details><summary><b>24. [7.21] gold-11</b> — Comparison Bet · geography, tvoje hodnotenie 9/10</summary>

**Q:** Which country consumes the most coffee per person: Brazil, the United States, or Finland?

**A:** Finland

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Remeselné podanie | **3.0** | 3.0 | 3.0 |
| Prerozprávateľnosť | **7.0** | 6.0 | 8.0 |
| Prekvapenie | **7.0** | 6.0 | 8.0 |
| Cesta k odpovedi | **7.0** | 6.0 | 8.0 |
| Rozprúdi debatu | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Remeselné podanie:** *gpt-5.6-sol:* The plausible Brazil and U.S. decoys add mild misdirection, but this remains a bare, undated ranking-recall question.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* The question is a straightforward, bare first-degree recall fact with multiple-choice options appended, lacking a clever angle or wordplay, which caps its score at 3.

</details>

<details><summary><b>25. [7.21] fixed-1</b> — FIXED anti-pattern · General</summary>

**Q:** Which capital city exists only because Sydney and Melbourne couldn't stand the idea of the other one winning the title?

**A:** Canberra

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Rozprúdi debatu | **5.5** | 6.0 | 5.0 |
| Cesta k odpovedi | **5.5** | 6.0 | 5.0 |
| Prekvapenie | **6.0** | 6.0 | 6.0 |
| Prerozprávateľnosť | **7.5** | 7.0 | 8.0 |
| Remeselné podanie | **8.0** | 8.0 | 8.0 |
| Vhodnosť za volant | **8.5** | 8.0 | 9.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>26. [7.21] fixed-4</b> — FIXED anti-pattern · General</summary>

**Q:** The USA celebrates its birthday on the 4th of July — yet most founding fathers actually signed the Declaration of Independence weeks later. In which month?

**A:** August

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Rozprúdi debatu | **5.5** | 6.0 | 5.0 |
| Remeselné podanie | **5.5** | 8.0 | 3.0 |
| Prekvapenie | **6.5** | 7.0 | 6.0 |
| Prerozprávateľnosť | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **7.5** | 7.0 | 8.0 |
| Cesta k odpovedi | **8.0** | 7.0 | 9.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>27. [7.29] fixed-2</b> — FIXED anti-pattern · General</summary>

**Q:** In Shakespeare's original Romeo and Juliet, how old was Juliet — an age that would horrify modern audiences?

**A:** 13

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **5.0** | 4.0 | 6.0 |
| Remeselné podanie | **6.0** | 5.0 | 7.0 |
| Rozprúdi debatu | **7.0** | 6.0 | 8.0 |
| Cesta k odpovedi | **7.0** | 6.0 | 8.0 |
| Prerozprávateľnosť | **8.0** | 8.0 | 8.0 |
| Vhodnosť za volant | **8.5** | 8.0 | 9.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>28. [7.29] fixed-7</b> — FIXED anti-pattern · General</summary>

**Q:** A newborn baby has about 270 bones, an adult only 206. What happened to the rest?

**A:** They fused together

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **4.0** | 6.0 | 2.0 |
| Rozprúdi debatu | **5.5** | 6.0 | 5.0 |
| Prerozprávateľnosť | **7.0** | 7.0 | 7.0 |
| Remeselné podanie | **7.0** | 7.0 | 7.0 |
| Cesta k odpovedi | **8.0** | 8.0 | 8.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Prekvapenie:** *gpt-5.6-sol:* The counterintuitive drop in bone count offers a satisfying biological reveal, though bone fusion is a fairly familiar trivia fact.
- **Prekvapenie:** *gemini-3.1-pro-preview:* This is a highly overexposed trivia staple found in countless basic science quizzes, removing any real surprise or 'aha!' moment.

</details>

<details><summary><b>29. [7.57] gold-25</b> — Estimation Challenge · science, tvoje hodnotenie 8/10</summary>

**Q:** In a room of just 23 people, what is the probability that two share a birthday: about 10%, 30%, or 50%?

**A:** About 50%

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Remeselné podanie | **5.0** | 7.0 | 3.0 |
| Prekvapenie | **6.0** | 4.0 | 8.0 |
| Cesta k odpovedi | **6.5** | 8.0 | 5.0 |
| Rozprúdi debatu | **8.0** | 7.0 | 9.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.0** | 9.0 | 9.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>30. [7.64] gold-2</b> — Surprising Connection · science, tvoje hodnotenie 9/10</summary>

**Q:** What everyday material connects a pencil, a tennis racket, and a diamond?

**A:** Carbon

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **5.5** | 7.0 | 4.0 |
| Prerozprávateľnosť | **7.0** | 8.0 | 6.0 |
| Rozprúdi debatu | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **8.0** | 7.0 | 9.0 |
| Remeselné podanie | **8.0** | 8.0 | 8.0 |
| Cesta k odpovedi | **8.0** | 8.0 | 8.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>31. [7.64] gold-13</b> — Estimation Challenge · science, tvoje hodnotenie 9/10</summary>

**Q:** If all the world's ice melted, would sea levels rise by about 2 meters, 20 meters, or 70 meters?

**A:** About 70 meters

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Remeselné podanie | **5.5** | 6.0 | 5.0 |
| Prekvapenie | **6.5** | 6.0 | 7.0 |
| Prerozprávateľnosť | **7.5** | 7.0 | 8.0 |
| Rozprúdi debatu | **7.5** | 7.0 | 8.0 |
| Cesta k odpovedi | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **9.0** | 9.0 | 9.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>32. [7.71] gold-16</b> — Reverse Engineer · history, tvoje hodnotenie 8/10</summary>

**Q:** Bubble wrap was originally invented and marketed as what kind of home product?

**A:** Textured wallpaper

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **4.5** | 5.0 | 4.0 |
| Remeselné podanie | **6.5** | 6.0 | 7.0 |
| Rozprúdi debatu | **7.5** | 7.0 | 8.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>33. [7.79] gold-17</b> — Scale Surprise · geography, tvoje hodnotenie 8/10</summary>

**Q:** Which country has more pyramids than Egypt?

**A:** Sudan

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **5.0** | 4.0 | 6.0 |
| Rozprúdi debatu | **7.0** | 6.0 | 8.0 |
| Remeselné podanie | **7.0** | 7.0 | 7.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Vhodnosť za volant | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>34. [7.79] gold-30</b> — true_false · history, tvoje hodnotenie 9/10</summary>

**Q:** True or false: Cleopatra lived closer in time to the Moon landing than to the building of the Great Pyramid.

**Možnosti:** A) True · B) False

**A:** a

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Remeselné podanie | **3.0** | 3.0 | 3.0 |
| Vhodnosť za volant | **7.0** | 7.0 | 7.0 |
| Cesta k odpovedi | **7.0** | 7.0 | 7.0 |
| Rozprúdi debatu | **8.5** | 8.0 | 9.0 |
| Prerozprávateľnosť | **9.0** | 9.0 | 9.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Prekvapenie | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |
| Kvalita distraktorov (determ.) | 10 | | |

**Prečo slabé dimenzie (sudcovia):**

- **Remeselné podanie:** *gpt-5.6-sol:* The striking counterintuitive claim makes “True” the obvious quiz-writer’s choice, so the true/false framing telegraphs the answer.
- **Remeselné podanie:** *gemini-3.1-pro-preview:* Presenting a highly specific, counter-intuitive 'fun fact' as a true/false statement makes 'True' the obvious meta-guess, triggering the telegraphed true/false penalty.

</details>

<details><summary><b>35. [7.86] fixed-3</b> — FIXED anti-pattern · General</summary>

**Q:** All of Earth's land — every continent and every island — could fit inside one ocean with room to spare. Which ocean?

**A:** The Pacific

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Rozprúdi debatu | **6.0** | 6.0 | 6.0 |
| Cesta k odpovedi | **7.0** | 7.0 | 7.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Remeselné podanie | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.0** | 8.0 | 8.0 |
| Vhodnosť za volant | **9.0** | 9.0 | 9.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>36. [7.93] gold-1</b> — Surprising Connection · history, tvoje hodnotenie 9/10</summary>

**Q:** Which spice was so prized the Dutch traded Manhattan for a tiny Indonesian island to control it?

**A:** Nutmeg

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **5.0** | 5.0 | 5.0 |
| Rozprúdi debatu | **7.5** | 7.0 | 8.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **8.5** | 8.0 | 9.0 |
| Remeselné podanie | **8.5** | 8.0 | 9.0 |
| Prerozprávateľnosť | **9.0** | 9.0 | 9.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>37. [8.0] gold-23</b> — Scale Surprise · nature, tvoje hodnotenie 9/10</summary>

**Q:** How many trees are there on Earth: closer to 400 million, 40 billion, or 3 trillion?

**A:** About 3 trillion

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Remeselné podanie | **7.0** | 7.0 | 7.0 |
| Prerozprávateľnosť | **7.5** | 7.0 | 8.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Vhodnosť za volant | **8.0** | 8.0 | 8.0 |
| Rozprúdi debatu | **8.0** | 7.0 | 9.0 |
| Cesta k odpovedi | **8.5** | 8.0 | 9.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>38. [8.07] gold-28</b> — Verbal Analogy · science, tvoje hodnotenie 8/10</summary>

**Q:** Mars is red, but what colour is a Martian sunset?

**A:** Blue

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **5.5** | 4.0 | 7.0 |
| Rozprúdi debatu | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.0** | 8.0 | 8.0 |
| Prekvapenie | **8.0** | 8.0 | 8.0 |
| Remeselné podanie | **8.0** | 8.0 | 8.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Vhodnosť za volant | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>39. [8.07] fixed-6</b> — FIXED anti-pattern · General</summary>

**Q:** Every atom of iron in your blood was forged in the same distant place. Where?

**A:** Inside a dying star

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **6.0** | 7.0 | 5.0 |
| Rozprúdi debatu | **7.5** | 7.0 | 8.0 |
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Remeselné podanie | **8.5** | 8.0 | 9.0 |
| Faktická istota | **9.0** | 8.0 | 10.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>40. [8.14] gold-20</b> — Scale Surprise · geography, tvoje hodnotenie 8/10</summary>

**Q:** Thanks to its overseas territories, one country spans 12 time zones — more than any other. What country?

**A:** France

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **7.0** | 6.0 | 8.0 |
| Rozprúdi debatu | **7.5** | 6.0 | 9.0 |
| Remeselné podanie | **7.5** | 7.0 | 8.0 |
| Prekvapenie | **8.0** | 8.0 | 8.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.0** | 9.0 | 9.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>41. [8.36] gold-22</b> — Scale Surprise · nature, tvoje hodnotenie 9/10</summary>

**Q:** Which is heavier: all the ants on Earth, or all the humans?

**A:** All the humans

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **6.0** | 7.0 | 5.0 |
| Remeselné podanie | **7.0** | 8.0 | 6.0 |
| Prerozprávateľnosť | **8.0** | 8.0 | 8.0 |
| Rozprúdi debatu | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Cesta k odpovedi | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>42. [8.36] fixed-12</b> — FIXED anti-pattern · General</summary>

**Q:** Australian police once worried that crime scenes could be contaminated by the fingerprints of which animal?

**A:** The koala

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **7.0** | 6.0 | 8.0 |
| Rozprúdi debatu | **8.0** | 8.0 | 8.0 |
| Prekvapenie | **8.0** | 8.0 | 8.0 |
| Remeselné podanie | **8.0** | 7.0 | 9.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>43. [8.5] gold-10</b> — Estimation Challenge · science, tvoje hodnotenie 9/10</summary>

**Q:** If you drove your car straight up at highway speed, how long would it take to reach space: about 10 minutes, 1 hour, or 6 hours?

**A:** About 1 hour

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **7.5** | 7.0 | 8.0 |
| Prerozprávateľnosť | **8.0** | 7.0 | 9.0 |
| Rozprúdi debatu | **8.0** | 7.0 | 9.0 |
| Remeselné podanie | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **9.0** | 9.0 | 9.0 |
| Cesta k odpovedi | **9.0** | 8.0 | 10.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>44. [8.5] gold-15</b> — Estimation Challenge · science, tvoje hodnotenie 9/10</summary>

**Q:** If you shuffled a deck of cards perfectly randomly, what are the chances that exact arrangement has ever existed before in history: roughly 50/50, about 1 in a million, or essentially zero?

**A:** Essentially zero

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Rozprúdi debatu | **8.0** | 7.0 | 9.0 |
| Prekvapenie | **8.0** | 7.0 | 9.0 |
| Remeselné podanie | **8.0** | 7.0 | 9.0 |
| Prerozprávateľnosť | **8.5** | 8.0 | 9.0 |
| Vhodnosť za volant | **8.5** | 9.0 | 8.0 |
| Cesta k odpovedi | **8.5** | 8.0 | 9.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>45. [8.57] gold-26</b> — Estimation Challenge · science, tvoje hodnotenie 9/10</summary>

**Q:** If you fold a standard piece of paper in half 42 times (if you could), how far would it reach: the ceiling, the top of Everest, or the Moon?

**A:** The Moon

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Prekvapenie | **7.5** | 6.0 | 9.0 |
| Remeselné podanie | **8.0** | 8.0 | 8.0 |
| Vhodnosť za volant | **8.5** | 9.0 | 8.0 |
| Rozprúdi debatu | **8.5** | 8.0 | 9.0 |
| Prerozprávateľnosť | **9.0** | 9.0 | 9.0 |
| Cesta k odpovedi | **9.0** | 9.0 | 9.0 |
| Faktická istota | **9.5** | 9.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

</details>

<details><summary><b>46. [8.86] gold-19</b> — Scale Surprise · history, tvoje hodnotenie 9/10</summary>

**Q:** Was Cleopatra closer in time to the building of the Great Pyramid or to the Moon landing?

**A:** The Moon landing

| Dimenzia | Priemer | gpt-5.6-sol | gemini-3.1-pro-preview |
|---|---|---|---|
| Cesta k odpovedi | **7.0** | 7.0 | 7.0 |
| Rozprúdi debatu | **8.5** | 8.0 | 9.0 |
| Remeselné podanie | **8.5** | 8.0 | 9.0 |
| Prerozprávateľnosť | **9.0** | 9.0 | 9.0 |
| Vhodnosť za volant | **9.5** | 9.0 | 10.0 |
| Prekvapenie | **9.5** | 9.0 | 10.0 |
| Faktická istota | **10.0** | 10.0 | 10.0 |
| Stručnosť odpovede (determ.) | 10 | | |

**Formátové flagy:** leak odpovede v zadaní: stem_leak(landing,moon)


</details>
