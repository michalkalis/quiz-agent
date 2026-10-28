# B2B: company quizzes played at work (2026-10-28)

**Idea (founder):** a company fills a web form about itself (or pastes a brief its own ChatGPT/Claude wrote from our prompt), instantly sees AI-generated sample questions about the company, pays on the web, and employees play the custom quiz together in Trubbo's multiplayer mode, with Trubbo moderating.

**Verdict: promising, but test it by hand first.** The value comes from the company's *internal* stories, not from what we can find on the web. Multiplayer, which the idea depends on, does not exist yet. A manual pilot with 1–3 firms can answer "do they enjoy it and would they pay" before we build the web form, payments or verification.

Related: [quiz-as-a-service research](quiz-as-a-service-2026-10-05.md) (verdict "not yet", corporate segment = high value, sales-led), [multiplayer research](multiplayer-same-room-2026-10-23.md).

## 1. Can an LLM write interesting questions about a company from public info?

Probe: 8 questions each from public sources only (Wikipedia, company site).

| Company | Public footprint | Good enough to show a buyer | Risky (unclear or perishable fact) |
|---|---|---|---|
| Kofola | 60+ years of history, rich wiki | ~5/8 (1970 vs 1996 production swing, 17 % vs 14 % SK survey, Čeko Libre with Tuzemák, Semtex via Pinelli) | 3/8 (sk/cs/en wikis conflict, unsourced claims) |
| Sygic | 20-year tech firm, thin culture info | ~2/8 (first iPhone navigation, Tripomatic) | 3/8 (CEO, map vendor, download counts go stale) |

- Public info is encyclopaedic, and employees already know most of it (founding year, founders). Most firms look like Sygic or have less.
- Missing, and only the company can supply it: stories, nicknames, office legends, "what new hires always ask", product anecdotes.
- Literature: LLM quiz items need a verify step. 2/3 of generated MCQs failed in one course study ([arXiv 2507.05629](https://arxiv.org/pdf/2507.05629)); distractors are the hardest part ([arXiv 2412.04185](https://arxiv.org/html/2412.04185v1)).
- **Implication:** "Trubbo finds out about the company itself" is a bonus, not the core. The form must ask for internal facts. Internal facts have no source URL, so the brief itself is the source and the buyer approves those questions before the game. That needs a new mode in our generation pipeline, which today requires a web source per question.
- Mixing in our general corpus (e.g. ~⅓ company, ⅔ general) lowers the dependence on the brief. Our general corpus is the strength nobody else has in sk/cs.

## 2. Market

- **Water Cooler Trivia:** weekly generic trivia, priced by participants ($10/mo up to 10, $100/mo up to 100, about $1/user/mo) ([pricing](https://www.watercoolertrivia.com/pricing)). About $300k ARR in 2021, net revenue retention just under 100 %, sold to employees rather than HR ([TechCrunch](https://techcrunch.com/2021/09/04/2197808/)).
- **QuizBreaker:** $39/mo up to 100 users, $249/mo unlimited; team members share fun facts ([pricing](https://quizbreaker.com/pricing)).
- **Kahoot! 360:** per host, about $25–54/mo ([pricing](https://kahoot.com/business/pricing/)). TriviaMaker and Quizado sell AI company-themed rounds (vendor claims).
- **No product found** that turns a web-form company profile into instant samples. This could be a gap, or a sign of weak demand.
- **CZ/SK:** Chytrý kvíz and Hospodský kvíz sell corporate quizzes with a live host. Prices are by request only (unverified, a mystery-shopper quote would settle it). The earlier estimate of €29–49 per event is still unverified.
- Demand evidence is thin. Assume one-off events (team-building, Christmas party, onboarding) before recurring weekly play.

## 3. Payments and Apple

- **App Store guideline 3.1.3(c), Enterprise Services:** an app "only sold directly by you to organizations or groups for their employees" may give access to content bought outside the app. "Consumer, single user, or family sales must use in-app purchase."
  - A company paying by Stripe on the web is allowed, but only as an organization sale. The app must not show a buy button or link for it, and individuals must never buy on that path.
  - A company code or QR code that unlocks content looks like 3.1.1 ("license keys… QR codes"), so the 3.1.3(c) exemption is what makes it OK. Worth asking App Review in advance.
- B2B in SK/CZ also needs proper invoices with company ID and VAT (reverse charge in the EU). Stripe Invoicing or a local invoicing tool covers this.

## 4. Data protection

- Public company info plus facts the company enters itself is low risk. Our terms need to say what we store and that it is sent to an LLM provider.
- **Employee personal data** (names, fun facts about people) is not covered by terms alone. The company is the controller and we are its processor, so we need a data processing agreement (GDPR Art. 28), a public list of sub-processors (the LLM providers) with a no-training commitment, and EU transfer safeguards.
- MVP: ask for no personal data about individuals; stories about teams and the company only.

## 5. Abuse of free samples

A sample costs cents. The real risk is spam and bots, not lost revenue. Suggested stack:

1. Cloudflare Turnstile on the form (free).
2. Email verification by magic link before samples are shown. A work domain gets the samples at once; Gmail etc. get a softer path, because many SK/CZ small firms use Gmail.
3. Show 3–5 samples and cache them per company domain.
4. Limits per IP and per domain, plus a global daily budget cap.

## 6. Getting recommended by ChatGPT and others

- Citing sources and statistics raised visibility by up to ~40 % in the Princeton GEO study ([arXiv 2311.09735](https://arxiv.org/abs/2311.09735)).
- AI answers lean on third-party pages: Reddit, YouTube and neutral comparison lists. Self-promotional lists are cited far less (vendor data, weak methodology).
- Our own blog helps less than getting into other people's "best team quiz apps" lists. Blog posts are worth writing only with concrete data and examples.

## Recommended next step: concierge pilot

1. 1–3 firms from the founder's network. Each sends a brief: our questionnaire, or the output of the prompt for their own ChatGPT/Claude.
2. We generate the quiz semi-manually (company questions + general corpus); the firm approves it.
3. They play it today without multiplayer: one phone on a speaker in a meeting room, Trubbo reads the questions, the room answers.
4. Measure: did people enjoy it, which questions landed, what would they pay, would they repeat it.
5. Only then decide on the web form, payments, verification and the multiplayer link.
