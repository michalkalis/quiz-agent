# Veľké AI asistenty ako konkurencia kvízov (2026-11-07)

Otázka foundera: ChatGPT, Meta AI (Muse Spark), Gemini a ďalší vedia kvíz na ľubovoľnú tému „zadarmo“ v predplatnom. Aká je teda pridaná hodnota Trubba, hlavne platených vlastných balíkov (10 otázok €3,49, 30 otázok €8,99)?

**Kvalita dôkazov:** prehľad funkcií konkurencie je stredne spoľahlivý (prevažne sekundárne zdroje). Reakcie ľudí sú slabé, ide o pár blogov a jedno vlákno na Reddite cez zrkadlo. Recenzie z App Store ani priame vlákna z Redditu sa nepodarilo získať. Štúdie o presnosti sú stredne silné, no malé a často na starších modeloch.

## 1. Čo ponúka konkurencia

| Produkt | Vlastná téma | Hlas | Herná slučka (skóre, séria, hra s inými) | Overenie faktov / zdroj pri otázke | Cena |
|---|---|---|---|---|---|
| Meta AI (Muse Spark) | len keď si o kvíz povieš v chate | áno | nie (vie postaviť minihru z promptu) | nie, surový výstup modelu | zadarmo |
| ChatGPT | áno (Study mode; samostatné „Quizzes“ od 08/2026, *neoverené*) | áno, aj CarPlay | len kontrola vedomostí, žiadne skóre ani hra s inými | nie | zadarmo / Plus |
| Gemini + NotebookLM | kvíz a kartičky z vlastných nahratých materiálov | Live, bez kvízového režimu, nie je v CarPlay | nie | NotebookLM: len z nahratých zdrojov | zadarmo ~10/deň |
| Claude | len cez prompt | áno, CarPlay od 29. 10. 2026 | nie | nie | predplatné |
| Copilot | Quiz Mode, kartičky | áno | nie | *neoverené* | zadarmo |
| Alexa+ / Volley | nie, pevný katalóg | áno, hlavná vec | áno (formáty ako v TV súťaži) | pevne zostavený obsah | Prime |
| Trivia Crack | AI kvíz „na takmer každú tému“ | nie | silná (súboje, postup) | nič | reklamy / €6,99 |
| Kahoot | z témy, PDF alebo Wikipédie | nie | hra naživo s rebríčkom | z dodaných zdrojov, bez citácie pri otázke | ~$3–35 mesačne |

Zdroje: [Muse Spark](https://about.fb.com/news/2026/04/introducing-muse-spark/), [ChatGPT Study mode](https://www.notebookcheck.net/OpenAI-adds-Study-Mode-to-ChatGPT-s-abilities.1072930.0.html), [ChatGPT Quizzes (neoverené)](https://promptoptimizer.tools/blog/chatgpt-quiz-me-feature-how-to-use), [NotebookLM](https://edu.google.com/ai-notebooklm/), [Claude CarPlay](https://www.iphoneincanada.ca/2026/10/29/claude-iphone-carplay-voice-mode/), [Grok CarPlay](https://macrumors.com/2026/05/08/grok-ai-voice-mode-apple-carplay/), [Alexa+](https://www.iclarified.com/99834/amazons-alexa-ai-assistant-launches-nationwide-in-the-us-included-with-prime), [Volley](https://www.volleygames.com/post/what-games-can-alexa-play), [Trivia Crack](https://apps.apple.com/us/app/trivia-crack-brain-quiz-games/id651510680), [Kahoot](https://kahoot.com/pricing-personal/).

**Závery:**
- Veľké asistenty majú kvíz ako **učebnú pomôcku, nie ako hru**. Nemajú trvalé skóre, série, hru s inými ani to, že sa otázky neopakujú.
- **Nikto neoveruje fakty pri otázke na voľnú tému** a nikto nepridáva zdroj ku každej otázke. Zdroje majú len kvízy z materiálov, ktoré si používateľ sám nahrá (NotebookLM, Kahoot).
- **Hlasový AI v aute je už bežná vec.** V CarPlay sú ChatGPT, Claude, Grok aj Perplexity. Samotné „hraj hlasom v aute“ nás už neodlišuje. Odlišuje nás až „hra so štruktúrou a overenými otázkami“.
- Slovenčinu ani češtinu v kvízoch konkurencie sme neoverovali.

## 2. Ako to ľudia vnímajú (slabé dôkazy)

- **Vymýšľa si a nepovie to.** Rodič hral s deťmi kvíz cez hlasový ChatGPT v aute. Model si vymyslel výsledky aktuálnej sezóny a deti zistili: „It's making stuff up.“ ([blog](https://www.aitoolsforkids.com/projects/chatgpt-voice-car-quiz-kids))
- **Pri hlasovom režime povie „Správne!“ aj na zlú odpoveď**, lebo je nastavený tak, aby bol príjemný (vlákno na r/ChatGPT cez [zrkadlo](https://reddit.birdcat.cafe/r/ChatGPT/comments/1kz16sg/the_latest_thing_i_have_found_that_chatgpt_is), anekdota). Hra bez férového rozhodcu nie je hra.
- **Prezrádza odpovede v pauzách**, hluk v aute ruší rozpoznávanie a relácia vyprší (ten istý blog).
- **Opakuje tie isté otázky a dáva príliš ľahké.** Pomôže až dlhý prompt typu „menej zrejmé otázky“ ([fórum OpenAI](https://community.openai.com/t/asking-for-a-questions-and-possible-answers-for-a-trivial-dataset-always-returning-same-questions/875166), [Wise Owl](https://www.wiseowl.co.uk/ai/blogs/ai/general/ai-quiz/)).
- **Pozitívne:** hlasový kvíz v aute funguje ako rodinná zábava a staršie, dobre zdokumentované fakty sedia.

## 3. Presnosť surových AI otázok (čísla)

- Medicínske štúdie: chyby v tvorbe otázky má **49–56 %** otázok od ChatGPT, u ľudí je to 27 %. Vecnú chybu má **~22 %** otázok. V štúdii so starším modelom bolo úplne správnych len 32 % ([BJO](https://bjo.bmj.com/content/110/7/836); Berman 2025, Ngo 2023).
- Faktografické testy (typ SimpleQA): aj najlepší model sa na ťažších, okrajových otázkach mýli zhruba v ~25 % prípadov. Kvíz žije práve z takýchto otázok (len sekundárny zdroj, treba overiť).
- **Naše vlastné dáta:** kontrola faktov zachytila 7 zo 7 podstrčených chýb pri cene ~4 ¢ za otázku. Na API ceste zadrží ~5–9 % otázok. Súhrnné číslo „koľko % otázok vyradíme“ zatiaľ nesledujeme.

## 4. Pridaná hodnota Trubba, nie je to len kontrola faktov

1. **Dôvera:** každú otázku pred hrou overíme na webe, k otázke patrí zdroj, a čo neprejde, ide von (radšej menej otázok ako zlá otázka). Toto nemá nikto.
2. **Je to hra, nie chat:** férový rozhodca, skóre, otázky sa neopakujú, obťažnosť, vysvetlenie po odpovedi a hra spolu v jednej miestnosti. Hráč nemusí nič písať do promptu.
3. **Kvalita zábavy:** otázky sú vybrané tak, aby prekvapili. Odfiltrujeme zrejmé a nejasné otázky aj otázky, ktoré prezrádzajú odpoveď. Duplicity vyhodíme.
4. **Natívna slovenčina a čeština** vrátane hlasových povelov.

**Slabiny, ktoré treba povedať nahlas:**
- Vlastný balík sa robí **26–31 minút**, ChatGPT odpovie hneď.
- **€8,99 za 30 otázok** pôsobí draho vedľa „zadarmo“, kým človek nevidí, čo za to dostane.
- **Rozpor v tom, čo tvrdíme:** web hovorí „každá otázka má overený zdroj“, App Store hovorí len „môže obsahovať chyby“ a aplikácia o overovaní mlčí.

## 5. Návrhy

1. **Ukázať overovanie v aplikácii**
   - Pri objednávke balíka: „Každú otázku overíme na webe a nepresné vyradíme.“
   - Po vygenerovaní balíka: „Overili sme 41 otázok, 11 sme vyradili, ostalo 30.“ Dáta už máme.
   - Na karte odpovede: štítok „Overené · zdroj“ namiesto holého „Zdroj“.
2. **Zjednotiť texty** na webe, v App Store a v aplikácii (sk/cs/en). Tvrdenie má byť pravdivé a opatrné: „každú otázku overujeme“, nie „bez chýb“. Upozornenie, že sa môžeme mýliť, ostáva.
3. **Formát na sociálne siete „AI si vymýšľa, my overujeme“:**
   - Vygenerujeme surový AI kvíz na 3–5 okrajových slovenských tém a necháme ho prejsť našou kontrolou.
   - Zverejníme skutočné číslo („z 30 otázok malo X chybu“) a jeden konkrétny príklad.
   - Značky konkurencie nemenujeme.
   - Náklad je približne $1–2.
4. **Vlastné balíky postaviť ako „pre partiu“:** narodeniny, firemný večierok, kvíz s kamarátmi cez hru spolu. Pre skupinu je €8,99 lacné. K tomu ukážka zadarmo (napr. prvé 2–3 otázky balíka, prípadne ukážkový balík).
5. **Rýchlosť:** prvé otázky pustiť do hry skôr (nadväzuje na #182 — rýchlejší štart vlastného balíka). Do čakania dať správu „práve overujeme otázku 12 z 30“, aby čakanie pôsobilo ako dôvod ceny.
6. **Sledovať metriku** „% vyradených pri kontrole“ pre každý balík. Potrebujeme ju pre bod 1 aj pre marketing.
