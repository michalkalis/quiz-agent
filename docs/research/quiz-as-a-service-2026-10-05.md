# Quiz-as-a-Service: market research (2026-10-05)

**Idea:** a website where quiz creators generate verified question packs (question + answer + explanation + source URL) on a chosen topic and export them (PDF, CSV, slides, Kahoot/Quizizz). Playing stays in the Trubbo iOS app.

**Verdict: NOT YET.** The self-serve AI generator slot is already crowded and cheap: free tools, $2-per-quiz tools, and a £9.99/mo unlimited AI pub-quiz tool. Our edge (source URL on every question, explanations, curated taste, CZ/SK) is real but narrow. Nothing yet shows that buyers will pay extra for it. Test cheaply after the App Store launch. Don't build a product yet.

Evidence quality: competitor prices are solid (fetched from vendor pages). Demand size and willingness to pay are **thin**. I found no reliable search-volume data, and Reddit can't be fetched from this environment. Venue counts are partial (London listings only, CZ operator self-reports).

---

## 1. Does it make sense? Segments ranked

| Rank | Segment | Willingness to pay | Reachability | Pain today | Notes |
|---|---|---|---|---|---|
| 1 | **Independent pub-quiz hosts (UK/IE/US/AU)** | Proven, low-to-mid: £2.50–£5 per weekly pack in the UK; $20–30 per quiz in the US | Medium: r/pubquiz, Facebook host groups, Etsy/Gumroad search | Writing ~50 good questions a week is time-consuming. They already pay suppliers ([PubQuizReady](https://www.pubquizready.co.uk/), [Pub Quiz Bros](https://thepubquizco.com/product/weekly-subscription-quiz/), [TheQuizmasters](https://www.thequizmasters.com/)) | Buys **ready-made, live-tested** packs, not a generator. TheQuizmasters sells on the claim "all of our quizzes are tested out LIVE at our own events" ([source](https://www.thequizmasters.com/)) |
| 2 | **Corporate / event / team-building organisers** | High per event, but irregular | Low: sales-led | Need custom topics (the company, the industry, a wedding couple) | CZ operators already sell corporate and wedding quizzes as a service ([Hospodský kvíz](https://www.hospodskykviz.cz/jdeme-poprve/), [Chytrý kvíz firemní akce](https://chytrykviz.cz/firemni-akce)) |
| 3 | **Casual hosts (family / party / one-off quiz night)** | Low, one-off ($1–15) | High via Etsy SEO | Want something printable tonight | Etsy bundles sell at $4–14, one with ~6,000 reviews ([Etsy market](https://www.etsy.com/market/pub_quiz_packs)). Volume is high, price is tiny |
| 4 | **Teachers** | Low individually; budgets sit at school/district level | High, but saturated | Need curriculum-aligned quizzes, not trivia | Served for free or nearly free: Brisk ([free](https://www.briskteaching.com/ai-tools/quiz-generator)), Conker ([$3.99/mo](https://www.toolsforhumans.ai/ai-tools/conker)), Wayground ([$12/mo](https://www.softwareadvice.com/student-engagement/quizizz-profile/)), Kahoot AI ([$12–25/mo](https://triviamaker.com/kahoot-pricing/)). **Poor fit** for "surprising fact" trivia |
| 5 | Streamers / radio / YouTubers | Unknown | Low | Content volume | No evidence found; speculative |

**CZ/SK reality check.** The organised scene runs on **operator-run brands**, not freelance hosts buying content:
- Hospodský kvíz: ~150 venues listed, "thousands" of players weekly, a national championship with ~150 teams ([hospodskykviz.cz](https://www.hospodskykviz.cz/jdeme-poprve/), [Deník](https://www.denik.cz/hobby/hospodsky-kviz-zabava-pamet-iq/)). It also runs in Slovakia ([hospodskykviz.sk](https://www.hospodskykviz.sk/podniky/mesto/bratislava)).
- Chytrý kvíz pays its moderators 500–1000 Kč per evening and supplies them with the quiz ([chytrykviz.cz](https://chytrykviz.cz/pro-podniky)).
- Wikipedia cites 35,000+ weekly quiz players in CZ ([cs.wikipedia](https://cs.wikipedia.org/wiki/Hospodsk%C3%BD_kv%C3%ADz)).
- Hospodský kvíz gives moderators a central manual ([Manuál moderátora](https://moderator.hospodskykviz.cz/files/Manual_moderator.pdf)). Inference: these operators write their own questions centrally, so they are **competitors or possible B2B licensees, not retail buyers**.
- I found no CZ/SK marketplace for buying quiz packs. The SK scene is small: a few Bratislava brands such as UniK and Mystery pub ([visitbratislava](https://www.visitbratislava.com/events/unik-pub-kviz-15/), [mysterypub.sk](https://mysterypub.sk/program)).

## 2. Competition and prior art

### Human-written pack suppliers (the incumbent for hosts)
| Supplier | Price | Format |
|---|---|---|
| PubQuizReady (UK) | £3.50/quiz, £2.50 with credit packs; 50 questions incl. picture round ([source](https://www.pubquizready.co.uk/)) | Print-ready PDF, custom logo on answer sheet |
| Pub Quiz Bros (UK/US) | £2.50/week or $4/week for 50 questions ([source](https://thepubquizco.com/product/weekly-subscription-quiz/)) | Weekly email |
| Bubble Tree Quizzes (UK) | £3.40/pack ([search summary](https://www.bubbletreequizzes.com/)) | Weekly download |
| Peacock Quizzes (UK) | from £5/night ([source](https://www.peacockquizzes.com/)) | Packs |
| TheQuizmasters (US) | $30/quiz; 8-quiz sub $160 = $20/week, prices unchanged since 2005 ([source](https://www.thequizmasters.com/)) | PDF, Excel, PowerPoint, web app; single-venue licence |
| Cheap Trivia (US) | $15.99/week or $59.99/month ([source](https://cheaptrivia.com/products/weekly-trivia-subscription-service)) | Weekly email |
| SpeedQuizzing (UK) | £7–21 per activation, a 61–67-question pack included ([source](https://www.speedquizzing.com/docs-live/speedquizzing-live-pricing/)) | Host software plus content |

### AI generators aimed at quiz nights (direct competitors, they exist already)
- **QuizVault (UK):** free plan (1 quiz/month), Pub plan **£9.99/mo unlimited**, Chain plan £29.99/mo for 20 venues. Claims "verified answers", quizmaster notes and print-ready A4 ([quizvault.co.uk](https://quizvault.co.uk/)). It positions itself directly against £5–30 packs.
- **LavaQuiz:** **$2 per new quiz**, $1 per library quiz, print-ready PDF, claims "fact checked", available in EN/SV/DE ([lavaquiz.com](https://lavaquiz.com/quiz)).
- **DailyQuiz.ai:** claims a second AI agent fact-checks every question and answer; targets pub quizzes, teams and classrooms ([dailyquiz.ai](https://www.dailyquiz.ai/ai-quiz-generator-for-pub-quizzes)). Pricing not found.
- **Quizquestions.org:** free, gives an explanation per question ([source](https://www.quizquestions.org/question-generator)).

### General and edu AI generators
Quizbot: free 50 questions/mo, $7.50–18.50/mo, prepaid 2,000 questions for $15; exports to Word, PDF, Kahoot, Moodle and others ([quizbot.ai](https://quizbot.ai/)). Quizgecko: enterprise from $500/mo with API access ([OMR](https://omr.com/en/reviews/product/quizgecko/pricing)). Kahoot AI on paid plans from $12/mo ([triviamaker](https://triviamaker.com/kahoot-pricing/)). Brisk is free and exports to Kahoot and Wayground ([Brisk](https://www.briskteaching.com/ai-tools/quiz-generator)). Many free one-page generators exist (Jotform, Opinion Stage, quiz-maker.com; [list](https://www.jotform.com/ai/trivia-generator/)).

### Is "just use ChatGPT" a killer objection?
**Partly yes.** For casual hosts and teachers, a free chatbot plus a quick check is good enough. ChatGPT now even runs interactive quizzes ([TechRadar](https://www.techradar.com/ai-platforms-assistants/i-tried-chatgpts-new-interactive-quizzes-on-5-subjects-i-thought-i-knew-well-it-quickly-found-the-gaps-in-my-knowledge)).

The counter-argument is accuracy. An older study found ChatGPT 3.5 produced fully correct questions with explanations in only 32% of cases, and 25% had wrong or misleading answers ([PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC10753050/)). That data is old (GPT-3.5) and its relevance to current models is **unverified**. Competitors already market "fact-checked" as a claim, so it is not a moat by itself.

### Our defensible edge (honest assessment)
1. **A source URL on every question** that the host can click to check. No competitor I checked shows citations; they only claim "verified". This edge matters in a contested pub answer ("show me"). **Medium strength.**
2. **Explanation / reveal text.** Quizquestions.org already does this for free. **Weak alone.**
3. **"Surprising fact" taste with quality scoring.** Real, but hard to show before purchase. Needs samples. **Medium.**
4. **Native-quality CZ/SK.** None of the AI tools I checked list CZ or SK; LavaQuiz offers EN/SV/DE. But the CZ/SK buyers are operators who write their own content. **Strong but tiny market.**
5. **Existing pipeline, so near-zero marginal cost.** True for us, but competitors get the same from cheap API calls. **Not a moat.**

## 3. Demand evidence

- **Paying behaviour exists.** Dozens of UK/US suppliers have sold weekly packs for years (TheQuizmasters since 2005, [source](https://www.thequizmasters.com/)). At least 20 US pub-quiz companies exist, and venues pay hosts $80–175+ per week ([Wikipedia](https://en.wikipedia.org/wiki/Pub_quiz)).
- **Volume signal.** London alone lists 186 weekly venues ([trivianearme](https://trivianearme.net/london-england-gb)). The top Etsy trivia bundle shows ~6,000 reviews ([Etsy](https://www.etsy.com/market/pub_quiz_packs)).
- **Communities.** Hosts trade rounds in r/pubquiz, r/trivia and Facebook host groups ([Quora summary](https://www.quora.com/Where-can-I-find-quality-pub-quiz-questions-and-answers)). Subscriber counts were **not verified**, because Reddit is blocked from this environment.
- **AI-generator demand.** QuizVault claims to have "served 45,000+ UK pubs" (according to a search-result snippet; **likely marketing, unverified**; [quizvault.co.uk](https://quizvault.co.uk/)).
- **Missing:** keyword volumes, conversion data for AI quiz tools, and any evidence that hosts pay a premium for citations. **This is the core unknown.**

## 4. Monetization options

| Model | Competitor anchors | Fit | Comment |
|---|---|---|---|
| Per-pack sale (custom topic) | LavaQuiz $2; PubQuizReady £2.50–3.50; Etsy $4–14 | Good for the first test | Matches what hosts already do. Low ticket, but no churn problem |
| Credits (prepaid) | Quizbot $15 / 2,000 questions; PubQuizReady credit packs; SpeedQuizzing credits | **Best primary model** | Cash up front, caps LLM cost, suits irregular event hosts |
| Weekly curated subscription (we pick the topics) | £2.50/week (Pub Quiz Bros) to $20/week (TheQuizmasters) | Good for regular hosts | Needs pub-specific extras (picture/music rounds, answer sheets, tie-breakers) that we don't produce today |
| Unlimited generator subscription | QuizVault £9.99/mo | Weak | Race to the bottom on price |
| B2B / education licensing | Kahoot/Wayground school plans | Poor | Our content is trivia, not curriculum; long sales cycles |
| White-label / API (license verified CZ/SK content to operators, radio, apps) | Quizgecko enterprise from $500/mo | Interesting, small | A handful of CZ/SK operators at most. Worth one sales email, not a product |

**Recommended pricing, if validated:**
- Credit packs: about **€4 per 50-question pack**, or €15 for 5 packs. This is priced slightly above PubQuizReady and LavaQuiz, justified by the citations.
- Optional "Host" subscription: **€9/mo** for 4 packs plus 1 ready-made weekly pack.
- CZ/SK custom/corporate packs: **€29–49** per event (estimate, not verified against CZ team-building prices).
- Avoid "unlimited".

**Revenue realism:** €1,000 MRR at €9/mo needs ~110 paying hosts. €5,000 MRR needs ~550. The same sum from €4 packs needs 250 or 1,250 packs a month. The UK supplier market has many small players at £2.50–5 per week, which suggests a fragmented, low-ARPU niche. For a solo founder this is **side income, not a company**, unless an API or white-label deal appears.

## 5. Risks

- **Distraction from the App Store launch (highest).** A web product, payments, export formats and support are a second product. Founder memory already says no large features before the first release.
- **Quality liability.** A wrong answer in a live pub quiz is public and embarrassing. Mitigations: source links plus a "report error / refund" policy. Support volume is unknown.
- **Cannibalization.** Low. Hosts aren't Trubbo players, and web packs can't be played in the app. The reverse might help: an "explanations + QR to play more in Trubbo" footer could work as a growth channel. Unverified.
- **Copyright.**
  - Our output: purely AI-generated output is likely **not copyrightable** in the US ([US Copyright Office Part 2, Jan 2025](https://www.copyright.gov/ai/); [Jones Day](https://www.jonesday.com/en/insights/2025/02/copyrightability-of-ai-outputs-us-copyright-office-analyzes-human-authorship-requirement)). Buyers could resell our packs, and the human curation/scoring step is the only protection. Use licence terms like TheQuizmasters' single-venue clause ([source](https://www.thequizmasters.com/)).
  - Inbound risk: facts themselves aren't copyrightable, but explanations must not copy source text verbatim.
- **Commoditization.** Model costs keep falling, and today's generator becomes a ChatGPT prompt next year. Only curation and trust last.
- **Support load.** One-off pub buyers ask for format tweaks such as picture rounds and answer sheets. Our pipeline has no image or music rounds, and pub hosts expect them ([PubQuizReady](https://www.pubquizready.co.uk/), [QuizVault](https://quizvault.co.uk/)).

## 6. Smallest experiment (after the App Store launch)

Do this by hand, with no new web app. Effort: a few agent steps plus founder posting time.
1. **Make 3 packs** from the existing corpus and pipeline: EN general (50 questions), EN themed, CZ general. Each is a print-ready PDF with answer, explanation and a clickable source per question.
2. **List them on Gumroad and Etsy** at €3–5, plus one free EN sample pack. Etsy gives search demand at no cost, and Gumroad gives a clean checkout.
3. **Post the free sample** once in r/pubquiz and 2–3 Facebook quiz-host groups, with the "every answer has a source" angle. Ask one question: would you pay for this weekly?
4. **CZ/SK B2B probe:** send one email each to Hospodský kvíz, Chytrý kvíz and one SK operator, offering a sourced question feed or white-label licence.
5. **Kill/continue gate (decide before starting):** for example, 20 or more paid sales, or 1 operator wanting a call, within the test window. Below that, shelve the idea. Above it, build only a credits page on top of the existing generation API.

Cost: roughly zero (Etsy listing fees are cents) plus founder time. Nothing touches the hot path or the quiz-pack-api deploy.
