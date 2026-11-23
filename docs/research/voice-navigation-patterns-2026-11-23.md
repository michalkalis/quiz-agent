# Hlasová navigácia a hovorené vedenie stavom: ako to robia iné platformy a appky

Dátum: 2026-11-23. Zadanie: ako iné appky a platformy vedú človeka hlasom (oznamovanie fáz, ticho, koniec relácie, povely, hluk). Cieľ: podklad pre zmeny v Trubbo po teste v aute. Zdroje sú len z webu, čo nie je overené, je označené „neoverené“.

## Zhrnutie
- Všetky veľké platformy (Alexa, Google, Android Auto) vedú používateľa **krátkou rečou, nie zvukmi**. Zvuk je doplnok, ktorý sa musí dať naučiť, preto ho radia používať striedmo.
- Ticho (no-input) sa rieši **najviac dvoma opakovaniami**, potom sa relácia slušne ukončí alebo prejde ďalej. Nikto neradí donekonečna otvárať mikrofón.
- Pri šoférovaní: **krátke toky, žiadne automatické prechody bez zásahu človeka, tempo ovláda šofér**.
- Povely a ich objavovanie: krátka slovná zásoba, tip na obrazovke, hovorený tip sa časom vytráca.

## 1. Oficiálne odporúčania platforiem

**Alexa.** Otázku položiť „až tesne pred otvorením mikrofónu“ a dať ju na koniec odpovede, aby človek nehovoril cez Alexu; „použi čo najmenej slov na čo najviac významu“; pri opakovaní skrátiť alebo vynechať úvod ([Alexa Haus, natural speech](https://developer.amazon.com/alexa/alexa-haus/natural-speech)). Opakované „žiadna odpoveď“ znamená, že človek pravdepodobne odišiel, a skill má reláciu ukončiť (tamtiež; číslo nie je uvedené). Chybová hláška nemá byť všeobecné „nerozumel som, zopakuj“, ale má pripomenúť, kde človek je, a vrátiť ho k podporovaným akciám; menu ponúka tri až štyri možnosti (príklad „plane, train, car, or bus“) ([Design the prompts](https://developer.amazon.com/en-US/docs/alexa/interaction-model-design/design-the-prompts-for-your-skill.html)). Hry: ucho nerado počuje to isté dvakrát, preto viac verzií tej istej odpovede; píš pre ucho a skúšaj nahlas; nepýtaj vstup po každom kroku (rozpoznávanie sa kazí) ([Best practices voice-first games, JP](https://developer.amazon.com/blogs/alexa/post/fcc7bc05-8cad-4669-9ae9-9ad48de830f6/best-practices-for-building-voice-first-games-for-alexa)). Alexa je z princípu ťahová, nie v reálnom čase (tamtiež).

**Google Conversation Design.** Najpresnejší rebríček pre ticho a nezhodu ([Errors](https://developers.google.com/assistant/conversation-design/errors)):
- No Input 1. stupeň: predpokladaj, že človek **otázku nepočul**; zopakuj ju stručne inými slovami; **nehovor „nepočul som ťa“**. Ak je človek možno zaseknutý, daj možnosti.
- No Input 2. stupeň: ešte raz otázka. Potom koniec. Najviac **2 opakovania**; nikdy viac než 3 chyby po sebe.
- No Match: 1. krátke ospravedlnenie a stručné zopakovanie (nie doslovne to isté, znie to roboticky), 2. príklady, čo povedať, potom slušné ukončenie.
- Ak informácia nie je povinná, ísť ďalej bez opakovania.

**Earcony.** Google: zvuk má jeden jasný význam; ak ho treba používateľa učiť, nepoužívať ho; používať striedmo, málo a rozoznateľné zvuky, čo najkratšie; hovorené tipy majú s učením miznúť („Wanna hear more?“ sa časom skracuje) ([Earcons](https://developers.google.com/assistant/conversation-design/earcons)).

**Android Auto (Android for Cars).** Toky 2 až 3 kroky (SHOULD), nikdy viac než 5; obsah ukázať aspoň 8 s pred automatickým prechodom; **nepoužívať automatické prechody za sebou bez zásahu používateľa**; zastaviť nahrávanie, keď človek prestane hovoriť ([UX requirements](https://developer.android.com/design/ui/cars/guides/ux-requirements/overview)). Viackrokové hlasové sekvencie majú byť prerušiteľné, obnoviteľné v logických bodoch a tempo ovláda šofér ([preloaded assistants UX](https://source.android.com/static/docs/automotive/voice/voice_interaction_guide/preloaded-assistants_UX-guidelines.pdf), zo súhrnu vyhľadávania, PDF som nečítal).

**Apple CarPlay.** Od iOS 26.4 je kategória „voice-based conversational apps“ ([entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.carplay-voice-based-conversation.md), [9to5Mac](https://9to5mac.com/2026/02/18/ios-26-4-adds-support-for-voice-based-ai-apps-to-carplay/)). Je pre appky, ktoré „odpovedajú na otázky a vykonávajú požiadavky“ (čet-boty); podľa tlače primárne hlasové rozhranie, najviac tri obrazovky, po interakcii uvoľniť audio session. Detaily sú z tlače a fór, nie z Apple príručky (HIG stránka mi vrátila 404). Pre Trubbo (bez konverzačného agenta) nie je cieľová kategória.

**NHTSA.** Oficiálne pokyny proti rozptýleniu (2013) hlasové úlohy **vyslovene nepokrývajú**; NHTSA len meria hlasové rozhrania (TDRT, pohľady) a plánovala fázu 3 ([Federal Register](https://www.govinfo.gov/content/pkg/FR-2012-02-24/html/2012-4017.htm), [report 2016](https://www.nhtsa.gov/sites/nhtsa.dot.gov/files/documents/8122314-in-vehvoicecntrlitrfaceperformeval.pdf)). Číselný limit dĺžky hlasovej úlohy som nenašiel. Hlasové rozhranie má vyššiu subjektívnu záťaž než dotykové ([PMC6588669](https://pmc.ncbi.nlm.nih.gov/articles/PMC6588669)).

## 2. Skutočné appky

- **Alexa kvízy (Jeopardy!, Song Quiz od Volley).** Vedú sa hlasom, Song Quiz hrá krátke ukážky a dáva čas „kým uplynie čas“, Echo Show pridáva vizuálnu animáciu ([Volley](https://developer.amazon.com/en-US/blogs/alexa/alexa-skills-kit/2022/08/Alexa-volley-august-2022), [Jeopardy blog](https://developer.amazon.com/blogs/alexa/post/f36e5480-dd21-43fd-b842-a349c9452926/jeopardy-america-s-favorite-game-show-celebrates-its-first-year-with-alexa)). Nič som nenašiel o konci hry ani „play again“ (neoverené, treba vyskúšať naživo).
- **Varenie bez rúk.** Google Home a Alexa vedú recept povelmi „next“, „repeat“, skok na číslo kroku, „ingredients“, „pause“ ([TechCrunch](https://techcrunch.com/2019/11/14/amazon-and-google-double-down-on-hands-free-recipes-to-help-sell-their-smart-displays), [Fortune](https://fortune.com/2017/04/26/google-home-cooking-voice-assistant/)). Test uvádza, že „next step“ niekedy zopakoval ten istý krok. Odporúčanie vývojárov: krátke ohraničené povely a **tlačidlo na dotyk pre každý hlasový povel**, lebo kuchyňa je hlučná ([Picovoice](https://picovoice.ai/blog/add-ai-voice-control-to-cooking-app/)).
- **Duolingo.** Tlačidlo „Can’t speak now“ preskočí hovorené cvičenia bez trestu na 15 minút, preskočenie sa dá vrátiť späť ([Android Authority](https://androidauthority.com/duolingo-undo-skip-speaking-button-3696590), [TV Tropes](https://www.tvtropes.org/pmwiki/pmwiki.php/VideoGame/Duolingo), neoficiálne zdroje). Vzor: **výslovné „teraz nemôžem“ bez trestu**, nie nútené opakovanie.
- **Intervalové časovače a tréning.** Appky inzerujú hovorené „3, 2, 1“ pred koncom fázy a hlasové ohlasovanie zmeny intervalu; hudba sa pri hlásení stíši (ducking) alebo mieša ([príklad](https://apps.apple.com/us/app/quick-hiit-timer/id6759736194), marketing výrobcov). Nike Run Club má vypínače Voiceover, Frequency, Countdown ([Nike](https://www.nike.com/help/a/nrc-settings)). Peloton/Strava/Zwift: **nič som nenašiel (neoverené)**. Spoločný vzor: hlásenie je hlasové a voliteľné, nie len pípnutie.
- **Navigácia.** Waze a Google Maps: hlasové povely sú len pri otvorenej appke cez Google Assistant, jazykovo a regionálne obmedzené ([Waze](https://support.google.com/waze/answer/6268717)). Údaje o krátkosti pokynov alebo zvonení pred hlásením som nenašiel (neoverené).
- **Apple Voice Control / Android Voice Access.** „Show me what to say“ ukáže zoznam povelov pre aktuálnu situáciu; „Show Hints“ sa objaví automaticky, keď si človek povie niečo blízke platnému povelu; „Show numbers“ očísluje položky ([Apple](https://support.apple.com/en-us/111778), [Google](https://support.google.com/accessibility/android/answer/6151854)). Vzor pre objaviteľnosť: **tip sa ukáže vtedy, keď je človek blízko, nie vždy**.

## 3. Vzory

**(a) Oznamovanie fáz: reč, zvuk, alebo oboje.** Platformy dávajú prednosť reči; zvuk iba keď má jeden jasný, naučiteľný význam. Najlepšie sa osvedčuje **jedno slovo tesne pred zmenou** (Alexa: otázka tesne pred mikrofónom). Zvuk len pre jednu vec (otvorený mikrofón), a krátky a tichý.

**(b) Viac času a ticho.** Google: 2 opakovania, potom koniec; pri no-input predpokladať, že človek nepočul, nie že zlyhal. Alexa: viac no-input znamená odchod. Android Auto: tempo ovláda šofér, sekvencie sú obnoviteľné. Duolingo: „teraz nemôžem“ bez trestu. Výslovné „daj mi viac času“ som v žiadnom zdroji nenašiel, je to naša inferencia.

**(c) Koniec relácie hlasom.** Alexa menu: 3 až 4 možnosti, otázka **na konci** vety; stop hláška jasne povie, že relácia končí („Thanks for using…, see you next time“). Google: po 2 tichách slušne skončiť. Android Auto: 2 až 3 kroky a ponúknuť „book again“ ako skratku pri opakovaní. Nenašiel som presné ticho-časovanie pre menu (neoverené).

**(d) Objaviteľnosť povelov.** Tip na obrazovke plus hovorený tip, ktorý sa pri učení skracuje (Google earcons). Pomoc vymenúva presne to, čo naozaj funguje (Alexa help prompt). Tip po „blízkej“ vete (Apple Show Hints).

**(e) Prerušenie reči (barge-in).** Telefónne príručky: rozhodni sa, kde je povolené, a drž to konzistentne; začiatok chybovej hlášky nechať doznieť; potrebné je potlačenie ozveny, inak mikrofón počuje vlastný hlas ([Avaya](https://support.avaya.com/elmodocs2/ir/15531.htm), [NVIDIA FAQ](https://perspectives.nvidia.com/nemotron-speech/task/faq/how-do-i-implement-barge-in-detection-so-a-user-can-interrupt-a-voice-agent-whil/)). Nie sú to príručky pre auto.

**(f) Hluk v aute.** Výskum: hluk z klimatizácie a vozovky zhoršuje rozpoznávanie, tlmenie šumu pomáha, pri niektorých autách horšie rozpoznávanie ženských hlasov ([SAE 2017-01-1693](https://saemobilus.sae.org/content/2017-01-1693), [HBK](https://www.hbkworld.com/es/knowledge/resource-center/articles/voice-recognition-in-the-auto-industry)). Čísla presnosti pre malé slovníky ani porovnanie s tlačidlom na volante som nenašiel (neoverené). Praktické vzory: krátky slovník, dotyková alternatíva pre každý povel (kuchyňa), Android Auto: tlačidlo mikrofónu ako vstupný bod.

**(g) Čísla, roky, dátumy v TTS.** Alexa SSML má `say-as` (cardinal, digits, ordinal, spell-out; dátumy v časti, ktorú som nedočítal) ([SSML reference](https://developer.amazon.com/en-US/docs/alexa/custom-skills/speech-synthesis-markup-language-ssml-reference.html)). ElevenLabs radí **písať čísla, dátumy a značky slovami tak, ako sa majú vysloviť**, pri krátkych alebo nejednoznačných textoch zadať jazyk (`language_code`) a vedieť, že normalizácia pridáva latenciu ([ElevenLabs help](https://elevenlabs.io/docs/help-center/product/core-capabilities/text-to-speech/why-are-numbers-dates-symbols-and-acronyms-not-properly-pronounced-or-spoken-in-the-correct-language)). Skutočnú výslovnosť sk/cs/uk treba otestovať, výsledok nie je zdokumentovaný.

## Čo z toho pre Trubbo

Zoradené podľa dopadu. Značky: [A] Alexa, [G] Google, [AA] Android Auto, [D] Duolingo, [Ap] Apple Voice Control, [E] ElevenLabs, [inf] naša inferencia.

1. **Povedz „Premýšľaj“ na začiatku odpočtu a „Odpovedaj“ tesne pred otvorením mikrofónu, jedno slovo, vždy rovnaké.** Mikrofón sa otvorí hneď po slove, aby človek nehovoril cez hlas. Zostane maximálne jeden tichý tón pre otvorený mikrofón. [A natural speech, G earcons]
2. **Ticho pri odpovedi: nespúšťaj nahrávanie znova.** Po prvom tichu hlas povie krátko možnosti („Opakovať, znova, alebo ďalej?“), mikrofón sa na odpoveď neotvorí; po druhom tichu otázka sa vyhodnotí ako preskočená, povie sa správna odpoveď a ide ďalej. Nepoužiť „nepočul som ťa“. [G no input: max 2, nehovor „nepočul som“; D bez trestu]
3. **Povel „ďalej“ počas premýšľania = „neviem“.** Ušetrí piaty povel; správna odpoveď sa prečíta. [D „Can’t speak now“, inf]
4. **Nič nezachytené: ponuka cesty späť na otázku.** „Nepočul som odpoveď. Znova, alebo ďalej?“ plus tlačidlo na obrazovke. Pri nezhode ukáž príklad, čo povedať. [G no match, A help]
5. **Koniec kvízu: povedz skóre jednou vetou a ponúkni najviac dve možnosti** („Znova, alebo ďalej?“) vo existujúcich povelov. Otázka je **na konci vety**. Ak je ticho, jedna zopakovaná otázka, potom ticho a koniec. [A natural speech, A menu 3 až 4, G end after 2]
6. **Žiadne automatické prechody za sebou.** Potvrdenie prepisu po 5 s a automatické ďalšie kolo sa nesmú reťaziť bez zásahu; ukázať obsah aspoň 8 s. Trubbo je na hranici (viď kontra nižšie). [AA UX requirements]
7. **Objaviteľnosť: hovorený tip raz pri prvom kvíze a potom sa vytráca; tip na obrazovke ostáva.** Pri blízkej, nerozpoznanej vete ukázať, ktorý povel mal prísť. [G earcons taper, Ap Show Hints]
8. **Prerušenie reči len pre „opakovať“ a „ďalej“ počas čítania otázky a vysvetlenia.** Najprv overiť, že mikrofón nepočuje vlastný TTS cez autoreproduktory; ak nie, vypnúť. [Avaya, NVIDIA]
9. **Krátke vety, rovnaké povelové slová, rôzne vety inde.** Povelové slová a fázy sa nemenia (učia sa), verdikty a vysvetlenia môžu mať varianty, aby sa neopakovali. [A games, G earcons]
10. **Dotyková alternatíva pre každý hlasový povel a MCQ ako záchrana v hluku.** Na obrazovke vždy veľké tlačidlá. [Picovoice, AA mic entry point; hluk SAE]
11. **Čísla a roky v TTS napísať slovami v jazyku appky** už v serveri, nie spoliehať sa na automatiku; pre krátke texty so samými číslami poslať `language_code`. Overiť sk/cs/uk výslovnosť vzorkou. [E]
12. **Nezaujímať sa o CarPlay „conversational“ kategóriu**, patrí chatbotom, nie hrám bez agenta. [Apple entitlement]

## Čo je v rozpore s tým, čo chce zakladateľ, alebo ho obmedzuje
- **Auto-potvrdenie po 5 s a automatický prechod** idú proti Android Auto pravidlu „žiadne automatické prechody za sebou bez zásahu, aspoň 8 s obsahu“. Oficiálne pravidlo platí pre aplikácie na displeji auta, nie pre telefón, takže je to odporúčanie, nie povinnosť.
- **Google radí pri tichu zopakovať otázku a znovu otvoriť mikrofón (2×)**; zakladateľ nechce nútené opakované nahrávanie. Navrhujem odchýlku (bod 2), ktorú podporuje Alexa („viac ticha = odišiel“) a Duolingo.
- **Hlasové menu na konci s viac možnosťami**: Alexa dovoľuje 3 až 4, ale pre auto a Trubbo odporúčam dve (štyri povely sú už rozhodnuté).
- **Tón + slovo**: platformy radia radšej reč ako zvuk; zakladateľ chce slová, zvuk len ako doplnok. Súhlasí.

## Medzery (neoverené)
Peloton/Strava/Zwift/NRC hovorené odpočty a oznamovanie intervalov; Waze/Google Maps krátkosť pokynov; Duolingo oficiálna pravidlá opakovania (15 minút pochádza z neoficiálnych zdrojov); NHTSA číselné limity hlasovej úlohy; presnosť malých slovníkov v aute a tlačidlo na volante; Alexa `say-as date` pre roky; konkrétne časovanie ticha pre koncové menu.
