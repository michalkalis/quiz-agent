# Corpus blind-rating vzorka — Opus 4.8 vs glm-5.2 (2026-07)

Vzorka pre gate **G3** ([`docs/setup/founder-human-gates-2026-07.md`](../../setup/founder-human-gates-2026-07.md) §2). Zdroj: 54 dogenerovaných otázok z `apps/quiz-pack-api/data/generation-2026-07-10/` (#72 resumed batch, 27× Opus 4.8 / 27× glm-5.2, founder-locked 1:1 split, `batch_review.md` #47–100). Nižšie je 10 náhodne vybraných (5 + 5), poradie zamiešané, model pri každej otázke schovaný — odhalí sa až v answer-key sekcii na konci.

**Výsledok nastaví default `GENERATION_MODEL` pre budúcu volume generáciu (#30/#95). Neblokuje N3 — tento batch (54 otázok) má 1:1 split už uzamknutý bez ohľadu na verdikt.**

## Ako hodnotiť

Ku každej z 10 otázok napíš verdikt **fun** alebo **flat**:
- **fun** = fun-fact charakter / genuiné prekvapenie ("nevedel som!") / skrytá vrstva (etymológia, pôvod, prepojenie) — nie suchý wiki recall.
- **flat** = klišé (videné milionkrát), suchý first-degree recall, vata v otázke, alebo craft chyba (odpoveď prezradená v texte otázky, nejednoznačné znenie, triviálne/zlé distraktory).

Plný rubrik s príkladmi: [`docs/research/question-quality-founder-calibration-2026-07-09.md`](../../research/question-quality-founder-calibration-2026-07-09.md).

Verdikty povedz orchestrátorovi v chate (otázka č. → fun/flat) — netreba editovať tento súbor. Answer key na konci si pozri **až po** ohodnotení všetkých 10 (nech ťa neovplyvní).

---

## Otázky

**1. [text_multichoice] General** — True or false: An octopus's beak is made of the same material as your fingernails.

   - Options: a) True · b) False
   - Answer: **True**
   - Context: Octopuses and squids have beaks made of keratin, the same protein that forms human fingernails. Since the beak is the only rigid part of an octopus's body, it can squeeze through any gap wide enough for its beak to pass, making it nature's ultimate escape artist.
   - Tvoj verdikt (fun / flat): ______

**2. [text] History** — In ancient Greece a citizen called a 'hippeus' was defined by owning which animal, whose Greek name also hides inside 'hippopotamus'?

   - Answer: **A horse**
   - Context: 'Hippos' is Greek for horse, so a hippeus was a horseman or cavalryman; hippopotamus literally means 'river horse'.
   - Tvoj verdikt (fun / flat): ______

**3. [text] Language** — The symbol '&', meaning 'and', has a proper one-word name derived from an old schoolroom phrase. What is that name?

   - Answer: **Ampersand**
   - Context: The name comes from 'and per se and', once recited at the end of the alphabet, which slurred together into 'ampersand'.
   - Tvoj verdikt (fun / flat): ______

**4. [text_multichoice] General** — In 1961, a Henri Matisse painting was discovered hanging upside down at New York's Museum of Modern Art. Roughly how many days had it been on display that way before anyone noticed?

   - Options: a) About 5 days · b) About 2 weeks · c) About 46 days · d) Nearly a year
   - Answer: **About 46 days**
   - Context: The painting 'Le Bateau' by Henri Matisse hung upside down at MoMA for around 46 days before anyone spotted the error. Thousands of visitors had walked right past it in that time. The mistake was finally pointed out by a visitor, not museum staff.
   - Tvoj verdikt (fun / flat): ______

**5. [text_multichoice] General** — In 1898 at Madison Square Garden, Nikola Tesla wirelessly steered a small boat with a remote, leaving the crowd so baffled that some thought what was hidden inside it?

   - Options: a) A trained monkey · b) A tiny motor · c) A magnet · d) A clockwork engine
   - Answer: **A trained monkey**
   - Context: Tesla's remote-controlled boat had a propeller, rudder, and two antennas. The audience was so confused by wireless control that some believed a trained monkey was steering it from inside.
   - Tvoj verdikt (fun / flat): ______

**6. [text] History** — Since the end of World War II, every British tank has come equipped with a built-in boiling vessel. What beverage is this primarily designed to make, allowing troops to stay protected inside the tank?

   - Answer: **Tea**
   - Context: All British tanks since 1945 have been fitted with a boiling vessel — essentially a built-in kettle — so crews can brew tea without leaving the safety of the armour. It's a uniquely British military tradition born from the harsh lesson that soldiers making tea outside their tanks were vulnerable to enemy fire.
   - Tvoj verdikt (fun / flat): ______

**7. [text] Weather** — For the first time in over 300 years of weather observations, England recorded what round-number temperature milestone during a devastating heat wave?

   - Answer: **100 degrees Fahrenheit**
   - Context: England had never hit 100°F in over three centuries of recorded observations. Paris simultaneously suffered nine consecutive days of at least 95°F, contributing to an estimated 70,000-plus excess deaths.
   - Tvoj verdikt (fun / flat): ______

**8. [text_multichoice] General** — Long before scuba gear existed, one Renaissance genius sketched a leather diving suit with breathing tubes, and even a built-in place for the wearer to relieve himself. Who designed it?

   - Options: a) Galileo Galilei · b) Leonardo da Vinci · c) Isaac Newton · d) Michelangelo
   - Answer: **Leonardo da Vinci**
   - Context: Leonardo da Vinci designed a leather scuba suit with air tubes, intended for naval attacks, and kept it a closely guarded military secret. It even included a place for the wearer to pee.
   - Tvoj verdikt (fun / flat): ______

**9. [text] Geography** — You're never more than six miles from a body of water in this U.S. state, which is also the only one made up of two distinct peninsulas. Name it.

   - Answer: **Michigan**
   - Context: Michigan has over 11,000 inland lakes and 3,000 miles of shoreline. Its mitten-shaped Lower Peninsula and thinner Upper Peninsula make it the only two-peninsula state.
   - Tvoj verdikt (fun / flat): ______

**10. [text] Space** — The Sun and Moon appear almost exactly the same size in our sky because of a striking coincidence: the Sun is about 400 times wider than the Moon, and also about 400 times what?

   - Answer: **Farther away**
   - Context: This near-perfect ratio is why total solar eclipses work, with the Moon just covering the Sun's disc. It's a cosmic coincidence unique to our era.
   - Tvoj verdikt (fun / flat): ______

---

## Answer key (nepozeraj pred hodnotením!)

| # | Model | Zdroj (id / súbor) |
|---|-------|---------------------|
| 1 | glm-5.2 | `71548bbb…` — part09.json#2 |
| 2 | claude-opus-4-8 | `b18bb4b2…` — part06.json#8 |
| 3 | claude-opus-4-8 | `9947efc3…` — part06.json#7 |
| 4 | glm-5.2 | `76f09798…` — part11.json#1 |
| 5 | claude-opus-4-8 | `ca6e2f87…` — part07.json#1 |
| 6 | glm-5.2 | `d015621d…` — part12.json#0 |
| 7 | glm-5.2 | `16ca15fb…` — part10.json#5 |
| 8 | claude-opus-4-8 | `49a044da…` — part07.json#3 |
| 9 | glm-5.2 | `38d79e68…` — part10.json#0 |
| 10 | claude-opus-4-8 | `6893e30e…` — part08.json#0 |

5× `claude-opus-4-8` (#2, #3, #5, #8, #10) · 5× `glm-5.2` (#1, #4, #6, #7, #9).
