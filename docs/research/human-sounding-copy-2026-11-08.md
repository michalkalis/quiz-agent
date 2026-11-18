# Copy that does not sound AI-written (sk · cs · en), research 2026-11-08

Why: founder flagged the promo narration „so zábavnými otázkami, nie školskými“ as AI-sounding; a person says „so zábavnými otázkami z bežného života“. Applies to all Trubbo texts: app UI, App Store, web, socials, video narration. Rules derived from this note: `docs/design/copy-style.md`, section „Sound like a person“.

Items marked **[unverified]** have no primary source; they are editorial judgment.

## 1. What the sources say

**Wikipedia, „Signs of AI writing“** (WikiProject AI Cleanup, the largest maintained catalogue of LLM tells; descriptive, not proof of AI): https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing
- *Negative parallelisms*: „Not X, but Y“, „Not just X, but also Y“, „Y rather than X“. A contrast with something nobody claimed, then the real point. Exactly the „nie školskými“ pattern.
- *Rule of three*: lists of three adjectives or three short phrases to look thorough.
- *Em dash overuse* (own section heading).
- *Puffery*: „stands as“, „is a testament to“, „vibrant“, „rich“, „profound“, „groundbreaking“, „nestled“, „in the heart of“.
- *Superficial -ing tails*: „highlighting…“, „fostering…“, „contributing to…“, „resonate with“.
- *Vague attribution*: „experts say“, „many people“.
- *Style*: Title Case headings, emoji at the start of headings or list items, heavy bold, curly quotes; chatbot phrases („Certainly!“, „I hope this helps“, „Let me know“).
- The page warns: one instance is not a problem; the pile-up is.

**Kobak et al., „Delving into LLM-assisted writing … through excess vocabulary“** (15.1 M PubMed abstracts): https://arxiv.org/abs/2406.07016
- After ChatGPT, style words jumped in frequency: „delves“ ×28, „showcasing“, „underscores“; also „potential“, „crucial“, „findings“. At least 13.5 % of 2024 abstracts were LLM-processed.
- Takeaway: the tell is a fixed set of *style* words (verbs and adjectives that add tone, not content).

**Juzek & Ward, „Why does ChatGPT ‚delve‘ so much?“**: https://arxiv.org/abs/2412.11385
- 21 focal over-used words; results consistent with RLHF (human preference tuning) pushing them. So every model keeps producing them unless told not to.

**Reinhart et al., „Do LLMs write like humans?“** (PNAS 2025, Biber feature set): https://arxiv.org/abs/2410.16107
- Instruction-tuned models use nominalizations at 1.5 to 2× the human rate and present participial clauses far more often; they write an „informationally dense, noun-heavy style“ and are bad at switching to other registers. Base models are closer to humans.
- Takeaway: verbs over nouns. „Kontrola odpovede“ is model style; „Trubbo skontroluje, čo si povedal“ is human.

**Nielsen Norman Group, Morkes & Nielsen 1997** (web writing study): https://www.nngroup.com/articles/applying-writing-guidelines-web-pages/ and https://www.nngroup.com/papers/webwriting/rewriting.html
- Concise text +58 % usability, scannable +47 %, objective (no promotional adjectives, buzzwords, unsupported claims) +27 %; all three +124 %. Promotional language costs readers effort because they must judge the claim.

**GOV.UK / GDS plain English, „words to avoid“** (secondary copies of the GDS list): https://readabilityguidelines.myxwiki.org/xwiki/bin/view/Plain%20English/Words%20to%20avoid/ , https://gist.github.com/fofr/505e225f9bf5e839d30c12ba6bfa0be2
- Avoid metaphors and abstract verbs: „deliver“ (only pizzas and post), „drive“ (only vehicles), „empower“, „facilitate“, „foster“, „leverage“. Use the plain word: help, make, give, use.

**Mailchimp Content Style Guide** (CC BY-NC): https://styleguide.mailchimp.com/tldr/ , https://styleguide.mailchimp.com/voice-and-tone/
- Short sentences, familiar words, active voice, no jargon; voice „human, familiar, straightforward“.

## 2. Slovak and Czech

**Czech is verbal, English nominal.** Czech translation studies note English packs meaning into nouns while Czech prefers verbs; carrying English noun clusters into Czech reads unnatural (Masaryk Univ. thesis): https://theses.cz/id/5oj6ry/DP_text_Novkov_2.pdf . Slovak behaves the same way **[unverified, no Slovak source found; same Slavic verbal structure]**.

**Calques are hard to spot.** Klégr & Bozděchová (Časopis pro moderní filologii 2022, 1 360 Czech calques) show semantic and multi-word calques grow as fast as borrowings: https://doaj.org/article/f4359c6acaaf45689a9acf204cbe8fb2 ; book „Lexikální anglicismy v češtině“ (Karolinum 2024, CC BY): https://directory.doabooks.org/handle/20.500.12854/139039 . Sicherl (Slovene, a close Slavic case) calls syntactic calques „invisible anglicisms“: only attentive readers sense „something sounds unusual“: https://ojs.unito.it/index.php/ricognizioni/article/view/11876

**LLMs write translationese in non-English languages.** „Lost in Literalism“ (2025): overly literal, unnatural phrasing persists in LLM output and comes from training: https://arxiv.org/abs/2503.04369 . Valentini et al. (COLM 2026) study translationese in multilingual LLM generations: https://arxiv.org/abs/2608.17399 . Czech is under-represented in training data (Milička et al. 2025): https://arxiv.org/abs/2509.22996 . Practical consequence: a sk/cs text written by a model is often an English sentence in Slovak words; read it as a native speaker would say it.

**Prepositions and collocations copied from English** **[unverified, editorial; no JÚĽŠ or ÚJČ ruling found online]**:
- „v tej istej Wi‑Fi“ (en *in/on the same Wi‑Fi*) → natural „na tej istej Wi‑Fi“ (sk usage on ISP and vendor pages: „pripojiť sa na Wi‑Fi“).
- „v aplikácii“ is fine; „na aplikácii“ is not. „Hrať na iPhone“ (device) but „hrať v kvíze“.
- „Urob rozdiel“ (*make a difference*), „dáva zmysel“ (*makes sense*, widely used, still a calque; prefer „je to logické“, „sedí to“ in formal-sounding places), „mať skúsenosť“ (*have an experience*) → „zažiť“.
- „Užite si…“ / „Užívaj si“ (*enjoy*) as a sign-off is a marketing calque; a Slovak friend says „Bav sa“ or nothing.

**Register.** Informal „ty“ (rule 1) plus spoken word order: verb early, subject often dropped („Ťukni na Štart“, not „Používateľ ťukne na tlačidlo Štart“). Avoid office nouns: „vykonať kontrolu“, „za účelom“, „realizovať“, „prostredníctvom“.

## 3. Tells relevant to Trubbo copy (ranked by how often we hit them)

1. **Contrast tail „X, nie Y“ / „not X, but Y“ / „not just X“**: denies something nobody said. Fix: say the positive thing concretely.
2. **Abstract nouns where a verb or a concrete noun works** („zážitok“, „obsah“, „funkcia“, „experience“, „content“): name the actual thing (otázky, kvíz, kamaráti).
3. **Triads**: three adjectives or three parallel benefits. Keep the one that matters, or two.
4. **Puffery and stock words**: en „seamless, elevate, unleash, delve, effortless, immersive, vibrant, ultimate, next-level, game-changer“; sk/cs „jedinečný, bezproblémový, posuň na novú úroveň, ponor sa, revolučný, dokonalý zážitok“.
5. **Rhetorical-question hooks** („Ready to…?“, „Chceš zažiť…?“) as filler openers. A real quiz question is fine (it is the product); a sales question is not.
6. **Dash rhythm** (already rule 5) and colon-reveal („Výsledok? Zábava.“).
7. **Over-parallel sentences**: every sentence the same length and shape. Spoken narration mixes 3-word and 10-word sentences.
8. **Emoji bullets, Title Case, bold sprinkles** on web and socials.
9. **Hedges and fillers**: „jednoducho“, „skutočne“, „naozaj“, „simply“, „just“, „truly“, „actually“ when they add nothing.
10. **Calqued prepositions / collocations in sk/cs** (section 2).

## 4. What makes it sound spoken

- Say it out loud as you would to a friend in the car; if you would not say it, rewrite (classic read-aloud test; Mailchimp, GDS).
- Concrete nouns and plain verbs: „otázky z bežného života“, „povedz odpoveď“, „kamaráti okolo teba“.
- One idea per sentence for narration and TTS; mix short and medium sentences.
- Say what happens, in order, from the player's side („Ťukneš, Trubbo prečíta otázku, odpovieš“).
- Specific beats generic: a number, a named topic, a real example question.

## 5. Limits

- No single tell proves AI authorship (Wikipedia caveat); rules target patterns that a reviewer can point to, not „vibe“.
- No primary Slovak/Czech source on LLM style or on „na/v Wi‑Fi“ was found; sk/cs preposition rules rest on native usage and founder judgment.
- The CI copy-review job only reads app strings (xcstrings, voice hints, crowd lines). App Store, web, socials and video scripts follow the same rules but are not checked by CI.
