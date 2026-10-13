# #200 — TF test redizajnu 1.1 (2026-10-12): 17 nálezov

**Triage:** bug · ready-for-human (kód hotový v main 2026-10-12; overenie na zariadení)
**Založené:** 2026-10-12 (founder testuje TF build redizajnu z `main`; beta `release/1.0` sa už neopravuje, redizajn ju nahrádza)

## Zistenia (recon origin/main 38c3d28a)

| # | Nález | Príčina |
|---|---|---|
| 1 | Hotovo v kategóriách: čierna kapsula v sklenenej lište | sklenená lišta je vždy, počet „vybraných: N“ len pri výbere (`HomeCategoryPicker.doneBar`); žiadny doložený dôvod pre počet |
| 2 | „lišta počúvania slová“, nejasné „Automaticky nahrávať / potvrdzovať“ | texty; „Hlasové príkazy“ má podnadpis, ktorý len opakuje názov |
| 3 | AirPods nie sú v zozname mikrofónov | zámer #104: mikrofón cez Bluetooth existuje len v režime hovoru (HFP); v bežnom režime ho iOS ani neponúkne |
| 4 | „Zvuky nahrávania“ bez vysvetlenia | = tón pri zapnutí mikrofónu |
| 5 | testovací riadok (model, jazyk, preklad) nalepený na kartu | 0 pt odstup (`QuestionProvenanceRow`) |
| 6 | Premýšľaj 45 s, v nastaveniach 20 s | dve nastavenia: „Čas na rozmyslenie“ (founder má uložených 45) riadi odpočet; „Časový limit na odpoveď“ platí len pri vypnutom automatickom nahrávaní → pre founderove nastavenie mŕtve |
| 7 | MCQ písmená A–D namiesto 1–4 | pravidlo foundera z #185 (09-24): písmená, keď odpovede obsahujú čísla; spúšťa ho akákoľvek číslica v ktorejkoľvek možnosti (`mcq_matcher._is_numeric_option`) |
| 8 | pauza počas čítania → po play sa nečíta ďalej | pauza audio zastaví a zahodí prehrávač; pokračovanie len znova spustí odpočet |
| 9 | „Moje balíky“ na domove občas chýba | sekcia sa skryje pri prázdnom zozname aj pri chybe načítania; zlyhané prvé načítanie sa už neopakuje (quiz-pack-api sa uspáva) |
| 10 | Vlastné balíky v nastaveniach úplne dole | poradie sekcií v `SettingsView` |
| 11 | „Vynuluj históriu otázok“ bez vysvetlenia; ostatné texty | „Oznamovať skóre nahlas“ je v skutočnosti stlmenie celého hlasu (aj čítania otázok); história je strop 500 a pri ňom sa kvíz **zablokuje** |
| 12 | spustenie balíka po štarte appky → chyba | **potvrdené v logoch produ 09:50Z:** DB spojenie zatvorené počas nečinnosti, výberový klient nemá kontrolu spojenia pred použitím (`pgvector_client` bez `pool_pre_ping`) → 500; „Skús znova“ navyše spustí bežný kvíz, nie balík |
| 13 | pauza počas Premýšľaj → odpočet odznova | zámerne „plné okno“ v #173 (napriek špecifikácii #171/#173 „zmraziť“) |
| 14 | balík hrá všetkých 30 otázok | server prepisuje počet otázok na veľkosť balíka (#182) |
| 15 | slovenské čísla/roky čítané zle (ženský hlas) | **kľúč ElevenLabs `carquiz` vyčerpal vlastný limit 10 000 kreditov** (účet má ešte ~20 000 do 20. 10.) → server prepol na záložný OpenAI hlas „nova“, ten číta číslice zle; rovnaký kľúč používa aj prepis reči (Scribe) → aj ten ticho prepol na zálohu; denná kontrola kreditov sleduje účet, nie limit kľúča; navyše hlas po odpovedi („Správna odpoveď je 1918“) čísla neprevádza a radové číslovky („19. storočí“, „1. mája“) sú zle |
| 16 | „Hraj znova“ po balíku spustí Zábavu | tlačidlo aj hlasový povel štartujú bez balíka |
| 17 | balík bez vlastného počítadla odohraných | dnes náhodou funguje cez spoločnú históriu (500, vynulovanie ju zmaže); po dohraní balíka surová chyba |

## Rozhodnutia foundera (2026-10-12)

- Redizajn nahrádza betu; beta sa už neopravuje. Kontrola „beta nie je vpredu“: jediný rozdiel = koniec kola bez počtu preskočených → **Správne / Nesprávne / Preskočené** namiesto Presnosti, body ostanú.
- **Automatické nahrávanie sa nedá vypnúť** (prepínač zmizne) → ostáva jediné nastavenie „Čas na rozmyslenie“; „Časový limit na odpoveď“ zmizne.
- **MCQ:** pravidlo písmen ponechať, spresniť: písmená len keď sú odpovede naozaj číselné (roky, počty, sumy), „Apollo 11“ ostane s číslami.
- **Balík si pamätá odohrané otázky** (na telefóne), hrá ďalších N neodohraných podľa nastavení, karta ukáže „10 / 30“, po dohraní ponuka „Hrať balík odznova?“; vynulovanie histórie balík neovplyvní.
- **História otázok:** žiadny strop, ktorý blokuje hranie, používateľ nevidí maximum; keď otázky naozaj dôjdu, ponúkne sa vynulovanie (existujúci tok #174). Technicky si appka pamätá posledných 5 000.
- **AirPods (upresnené 2026-10-12):** appka ukáže, že sú pripojené BT slúchadlá (zvuk ide do nich, odpovede nahráva mikrofón iPhonu); režim hovoru sa pri slúchadlách **nezapína** (nie je potrebný, zhoršil by zvuk a v aute sa tvári ako hovor); prepínač v nastaveniach ostáva.
- Kategórie: počet „vybraných“ preč, jedno tlačidlo Hotovo bez vnorenej lišty.

## Tracky

- [x] **200.1 — HOTOVÉ 2026-10-12 (PR #371, #372, nasadené v151; cache nahrávok 1 500 MB PR #374, v152) — backend:** (a) výberový klient DB `pool_pre_ping` (#12), počet otázok balíka = min(nastavenie, balík) (#14), spresnené pravidlo písmen MCQ (#7); (b) čísla v hlase po odpovedi + radové číslovky sk/cs, upozornenie (Sentry), keď TTS/STT prepne na zálohu pre limit (#15).
- [x] **200.2 — HOTOVÉ 2026-10-12 (PR #377, #381 zastavené sekundy počas pauzy) — iOS pauza a odpočty:** pauza počas čítania otázky pokračuje od miesta zastavenia (#8); pauza počas Premýšľaj pokračuje so zvyškom času (#13); bez prepínača automatického nahrávania a bez „Časového limitu na odpoveď“ (#6).
- [x] **200.3 — HOTOVÉ 2026-10-12 (PR #376, RS-24) — iOS balíky a história:** „Hraj znova“, „Skús znova“ a hlasové „znova“ ostanú v balíku (#16, #12); počítadlo odohraných otázok balíka + „N / M“ na karte + ponuka odznova (#17); sekcia Moje balíky vždy s nadpisom a stavom načítania / prázdna / chyba + opakovanie (#9); história bez blokujúceho stropu (okno 5 000).
- [x] **200.4 — HOTOVÉ 2026-10-12 (PR #373) — iOS nastavenia a drobnosti:** texty a podnadpisy sk/cs/en (#2, #4, #11, „Oznamovať skóre nahlas“ → zodpovedá tomu, čo robí), Vlastné balíky vedľa Predplatného (#10), história bez „/ 500“, kategórie s jedným tlačidlom Hotovo (#1), odstup testovacieho riadku (#5), koniec kola Správne / Nesprávne / Preskočené.
- [x] **200.5 — HOTOVÉ 2026-10-12 (PR #375) — iOS mikrofón:** zoznam mikrofónov ukáže pripojené BT slúchadlá (zvuk v nich, nahráva iPhone), bez prepínania do režimu hovoru (#3).
- [x] **200.6 — HOTOVÉ 2026-10-12 — founder:** limit kľúča `carquiz` v ElevenLabs zrušený (#15).
- [x] **200.7 — odhad spotreby ElevenLabs HOTOVÝ 2026-10-12:** TTS 98 % kreditov, ~185 kreditov pri prvom prečítaní otázky (potom zdieľaná cache), celý korpus raz ~680k kreditov (~$136); Starter nevie dokúpiť → founder žiada o ElevenLabs Startup Grant (rieši iná session, memory `project_elevenlabs_cost_grant_2026_10_12`); plán B 1 mesiac Pro na prečítanie korpusu.

## Zostáva

- Overiť na zariadení (TF build na požiadanie): pauza počas čítania a Premýšľaj, balík (počet otázok, Hraj znova, „Odohrané N / 30“, ponuka odznova), AirPods v zozname mikrofónov, slovenské čísla hlasom ElevenLabs.
- Neskôr (nízka priorita): po aktualizácii začne každý balík od nuly (staré odohrané otázky sa nedajú priradiť).
- **Hotové 2026-10-13:** rekapitulácia zdieľateľná v cache, číslo otázky je samostatná nahrávka, verdikt s odpoveďou sa zdieľa medzi hráčmi (PR #387); Moje balíky výzvu na prihlásenie ukážu len odhláseným, inak „Tvoje balíky sa nepodarilo načítať“ + Skús znova (PR #388).

## Hotovo, keď

Všetkých 17 bodov opravených alebo vysvetlených a odsúhlasených; každý stavový bug (pauza, časovače, balíky) má deterministický test; texty sk/cs/en; PR zlúčené, backend nasadený; TF build na požiadanie foundera.
