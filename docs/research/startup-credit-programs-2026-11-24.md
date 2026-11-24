# Rešerš: startup programy a kredity pre Trubbo

**Dátum:** 2026-11-24 | **Otázka:** Anthropic startup program (mesačná suma), iné programy, môže sa Trubbo (missinghue s.r.o.) prihlásiť?

Východisko: missinghue s.r.o. (CZ, založená 7/2018, bez investora, 1 človek), Trubbo od 12/2025. Už máme: AWS Activate Founders $1 000 (do 2028), ElevenLabs grant 33M kreditov (do ~11/2027), Anthropic API kredit z Max $200/mes. Prihláška do Claude for Startups 10-08 zablokovaná pravidlom veku firmy, žiadosť o výnimku čakala na posúdenie.

## Zhrnutie

- **„Mesačná suma“ od Anthropicu nie je startup program, ale súčasť predplatného:** Max $100/mes, Ultra $200/mes, Team až $500/mes API kreditu. Founder ju už čerpá ($200/mes).
- **Claude for Startups je zatvorený** (kohorta plná, nové prihlášky neprijímajú, dátum znovuotvorenia nie je). Prihlášky, ktoré boli v posudzovaní, podľa Anthropicu „nepostúpili“ → naša žiadosť o výnimku z 10-08 tým takmer určite padla.
- Program aj tak nikdy nedával mesačnú sumu: bol to jednorazový $1 000 kredit (6 mes.) + rok Claude Team; dnes už len partnerské zľavy (do $45k) a až $100k cez partnerský VC fond.
- Väčšina štedrých programov (Google AI $350k, AWS Portfolio $200k, Microsoft $100k+, OpenRouter, OpenAI) vyžaduje investora, akcelerátor alebo partnerský kód. Bez toho ostávajú malé sumy.
- Firma z 2018 prejde tam, kde je limit 10 rokov (AWS, Cloudflare, NVIDIA), neprejde pri limite 2 až 5 rokov (Anthropic, Google Start, Sentry, PostHog, JetBrains).

## Anthropic

| Čo | Výška | Stav pre nás |
|---|---|---|
| Max / Ultra predplatné | $100 / $200 API kreditu mesačne, nevyčerpané prepadá | Máme ($200/mes) |
| Team predplatné | Standard miesto $20, Premium $100 kreditu/mes, spolu max $500/mes, jedna Console org | Neoplatí sa: kredit ≈ cena miest (Premium $100–125/miesto), pre 1 človeka nič navyše oproti Ultra |
| Claude for Startups | Partnerské zľavy do $45k, office hours; do 10-09 aj rok Team + $1 000 API | Zatvorené, čakať na novú kohortu (newsletter) |
| VC cesta | Až $100k API kreditu cez partnerský fond | Nemáme investora |
| AI for Science, Team pre vedcov | Pre výskumníkov a univerzity | Netýka sa nás |

Kredity zo startup programu platia len na priame Claude API (nie Bedrock, nie OpenRouter).

## Iné programy, kam sa reálne dá ísť

| Program | Čo dostaneme | Prečo áno | Užitočnosť pre Trubbo |
|---|---|---|---|
| NVIDIA Inception | Členstvo zdarma, odporúčania na cloud kredity | Firma < 10 r., web, bez poplatku | Stredná: možná cesta k AWS Activate Portfolio (do $200k, Bedrock Claude) |
| AWS Activate Founders (navýšenie) | Do $5 000 (máme $1 000) | Bez investora, < 10 r. | Stredná: požiadať podporu o navýšenie |
| Cloudflare for Startups, Tier 3 | $10 000 na 1 rok | Bez investora, < 10 r. | Nízka: AI služby nekryje, hosting máme na Hetzneri |
| Microsoft for Startups (open) | $1 000 na 90 dní + $4 000 na 180 dní Azure | Nový Azure účet | Nízka až stredná: len ak by sme použili Azure OpenAI |
| Deepgram | $1 000, až $100k, 12 mes. | < $10M, vlastný hlasový produkt | Nízka: STT máme cez ElevenLabs grant, záložná možnosť |
| Together AI | Do $15k | Výber cez formulár | Nízka: lacné open modely na offline úlohy |
| Tavily | 10k kreditov aj pri zamietnutí | Zadarmo | Nízka: len ak treba webové vyhľadávanie |
| Amplitude, Mixpanel | Rok zadarmo | Bez investora | Len pri zmene analytiky |
| Apple Small Business Program | 15 % namiesto 30 % | Príjem < $1M | Overiť v App Store Connect, že je aktívny |

## Kam nie (alebo zatiaľ nie)

- **Google for Startups Cloud:** Start tier ($2 000) chce firmu ≤ 2 roky; AI tier ($350k) chce investora. Kredity aj tak nejdú na Gemini API cez AI Studio.
- **OpenAI:** verejný program nie je, len cez partnerské fondy.
- **OpenRouter, GitHub, Vercel, Groq, Fireworks:** len s odporúčaním partnera alebo investorom.
- **Sentry, PostHog, JetBrains:** limit veku firmy 2 až 5 rokov.
- **DigitalOcean Hatch:** pozastavený do začiatku 2027. **Hetzner:** startup program nemá.

## Verejné peniaze a akcelerátory

- **CzechInvest Technologická inkubácia:** do 5 mil. Kč, ale 7. výzva sa zavrela 2026-01-12 a mala byť posledná. Predinkubácia celoročne, overiť.
- **Státní fond audiovize, podpora videohier:** prvé výzvy až 2027 (pilotný rok), pravidlá ešte nie sú. Sledovať.
- **Creative Europe MEDIA (videohry):** chce príbehové hry; výzva 2026 zavretá. Kvíz sa sem hodí slabo.
- **EIC Accelerator, TA ČR, OP TAK:** pre deep-tech a výskum, nie pre nás.
- **Akcelerátory** (YC, Techstars, StartupYard): peniaze za podiel vo firme. Vedľajší efekt: dávajú partnerské kódy, ktoré odomknú AWS, Google, Microsoft aj Anthropic VC cestu.

## Odporúčanie

1. Anthropic: nič nepodávať, prihlásiť sa na newsletter Claude Startups; ostať na Max/Ultra ($200/mes).
2. NVIDIA Inception: prihlásiť (zadarmo), potom skúsiť cez ňu AWS Activate Portfolio.
3. AWS: požiadať o navýšenie Founders kreditu na $5 000.
4. Malé a lacné: Cloudflare Tier 3 a Tavily len ak ich začneme používať; Deepgram ako záloha k ElevenLabs.
5. Sledovať: Státní fond audiovize 2027, nová kohorta Claude Startups, DigitalOcean 2027.

## Zdroje

1. [Claude Startups (oficiálne)](https://claude.com/programs/startups) — kohorta plná, prihlášky zatvorené, $45k partnerské zľavy, $100k cez VC
2. [Claude pricing](https://claude.com/pricing) — Max $100, Ultra $200, Team do $500 API kreditu mesačne
3. [Monthly API credits for Max and Team](https://support.claude.com/en/articles/17154008) — $20/$100 za miesto, strop $500, jedna Console org
4. [Pozastavenie programu 10-09](https://pasqualepillitteri.it/en/news/22152/anthropic-pauses-free-claude-team-api-credits) a [prihlášky v posudzovaní](https://magica.com/news/anthropic-pauses-startup-credits-after-application-surge) — sekundárne zdroje
5. [AWS Activate](https://aws.amazon.com/startups/credits) — Founders do $5 000, Portfolio do $200k cez poskytovateľa
6. [Google for Startups AI](https://cloud.google.com/startup/ai) a [Start tier](https://cloud.google.com/startup/pre-funded)
7. [Microsoft for Startups zmeny](https://learn.microsoft.com/en-us/startups/changes-microsoft-for-startups)
8. [Cloudflare for Startups](https://www.cloudflare.com/forstartups/)
9. [NVIDIA Inception](https://www.nvidia.com/en-us/startups/)
10. [Deepgram startup program](https://deepgram.com/startup-program), [Together AI](https://www.together.ai/startup-accelerator), [Tavily](https://tavily.com/startups), [OpenRouter](https://openrouter.ai/startup-program), [DigitalOcean Hatch](https://www.digitalocean.com/hatch)
11. [Sentry](https://sentry.io/for/startups/apply/), [PostHog](https://posthog.com/handbook/marketing/startups), [Apple Small Business Program](https://developer.apple.com/app-store/small-business-program/)
12. [Technologická inkubácia](https://technologickainkubace.org/en/), [SFA videohry (Lupa)](https://www.lupa.cz/clanky/statni-fond-poprve-podpori-videohry-na-vyvoj-a-vyrobu-vycleni-tricet-milionu/), [Creative Europe video games](https://www.developmentaid.org/grants/view/1548337/video-games-and-immersive-content-development)

Neoverené na oficiálnej stránke: Google sumy (orezané stránky), OpenAI, Mistral, Vercel, presné dátumy pozastavenia Anthropic programu.
