# Slepý test štruktúry otázky — SK (2026-09-21)

Model session:opus cez session, prompt corpus-v2, seed 2026. Hodnotenie 1–10 z rating webu.

| Verzia | Hodnotených | Priemer | ≥ 8 | Kritické nálezy brány |
|---|---|---|---|---|
| retranslate | 19 | 9.0 | 16 | 1 |
| rewrite | 20 | 9.2 | 19 | 0 |

## food-everyday · buried · `00e29bed`

**Originál (v prode):** Najznámejšie hviezdičkové hodnotenia reštaurácií na svete udeľuje sprievodca, ktorý vznikol v roku 1900, aby sa predával istý produkt. Ktorý?
Odpoveď: Pneumatiky

**retranslate** (**10.0/10**)
Najznámejšie hviezdičkové hodnotenie reštaurácií na svete udeľuje sprievodca, ktorý vznikol v roku 1900 preto, aby pomohol predávať istý výrobok. O aký výrobok išlo?
_brána: čistá_

**rewrite** (**8.0/10**) — "vznikol v roku 1900, aby pomohol predávať istý produkt" - proste predaval iny produkt
Najznámejšie hviezdičkové hodnotenia reštaurácií na svete udeľuje sprievodca, ktorý vznikol v roku 1900, aby pomohol predávať istý produkt. Ktorý produkt to bol?
_brána: čistá_

## kids · buried · `035077c2`

**Originál (v prode):** Na štandardnej šesťstennej hracej kocke dávajú čísla na ľubovoľných dvoch protiľahlých stenách vždy v súčte koľko?
Odpoveď: Sedem

**retranslate** (**10.0/10**)
Na štandardnej šesťstennej hracej kocke dávajú čísla na dvoch protiľahlých stenách vždy rovnaký súčet. Koľko je tento súčet?
_brána: čistá_

**rewrite** (**8.0/10**) — trochu tazko pochopitelne. mozno lepsie rozdelit do
Koľko dávajú v súčte čísla na ľubovoľných dvoch protiľahlých stenách štandardnej šesťstennej hracej kocky?
_brána: čistá_

## sports-mix · buried · `0830cc7d`

**Originál (v prode):** Olympijská zlatá medaila je takmer celá vyrobená z ktorého kovu?
Odpoveď: Striebro

**retranslate** (**6.0/10**)
Z ktorého kovu je takmer celá vyrobená olympijská zlatá medaila?
_brána: čistá_

**rewrite** (**5.0/10**) — to neni dobry preklad. spravne by bolo napriklad "prevazne z ktoreho kovu je vyrobena olympijska zlata medaila?" alebo "olympijska zlata medaila je takmer cela vyrobena z jedneho kovu. aky to je kov?" pripadne ine varianty
tu je zly slovosled a tym padom ta otazka nedava moc zmysel. keby sa pouzije tento tvar, tak spravne by bol "z ktoreho kovu je olympijska zlata medaila takmer cela vyrobena?"
Z ktorého kovu je takmer celá vyrobená olympijská zlatá medaila?
_brána: judge: minor lexical_calque — Literal rendering of "gold plated on top" — the gold itself is described as gilded, which is semantically odd in Slovak (natural: "len asi šesť gramov zlata na povrchu"), but the explanation still supports the same answer and causes no grading harm._

## food-everyday · buried · `086a3325`

**Originál (v prode):** Vanilka je podľa hmotnosti druhé najdrahšie korenie na svete. Je to ručne opeľovaný a fermentovaný semenný lusk ktorej čeľade kvitnúcich rastlín?
Odpoveď: Orchidey

**retranslate** (**10.0/10**)
Vanilka je druhé najdrahšie korenie na svete podľa hmotnosti. Získava sa z ručne opeľovaných a následne fermentovaných semenných toboliek. Z ktorej čeľade kvitnúcich rastlín pochádza?
_brána: čistá_

**rewrite** (**9.0/10**)
Vanilka je podľa hmotnosti druhé najdrahšie korenie na svete. Je to ručne opeľovaný a fermentovaný semenný lusk rastliny. Z ktorej čeľade kvitnúcich rastlín pochádza?
_brána: čistá_

## sports-mix · control · `086b4a11`

**Originál (v prode):** Na olympiáde v Paríži 2024 plavci označovali bazén za 'pomalý' a padlo prekvapivo málo svetových rekordov. Mal štandardnú dĺžku aj teplotu, ale hĺbku len asi 2,15 metra namiesto obvyklých 3 metrov. Prečo by plytší bazén mal plavcov spomaliť?
Odpoveď: Vlny sa odrážajú od dna a zvyšujú turbulenciu

**retranslate** (**10.0/10**) — vysvetlenie obdobne ako prva otazka
Na olympiáde v Paríži 2024 plavci označovali bazén za „pomalý“ a padlo prekvapivo málo svetových rekordov. Mal štandardnú dĺžku aj teplotu, ale hĺbku len asi 2,15 metra namiesto obvyklých 3 metrov. Prečo by plytší bazén robil plavcov pomalšími?
Odpoveď zmenená: Vlny sa odrážajú od dna a vytvárajú turbulenciu
_brána: čistá_

**rewrite** (**9.0/10**) — preklad vyzera byt v poriadku, len dlzka odpovede je trochu kriticka by som povedal a bude takze pre model vyhodnotit spravnost
Na olympiáde v Paríži 2024 plavci označovali bazén za 'pomalý' a padlo prekvapivo málo svetových rekordov. Mal štandardnú dĺžku aj teplotu, ale hĺbku len asi 2,15 metra namiesto obvyklých 3 metrov. Prečo by plytší bazén mal plavcov spomaliť?
_brána: judge: minor other — The Slovak alternative_answers list has six entries where the source has five — this extra accepted paraphrase was added in translation; it is semantically consistent with the correct answer, so it only makes grading slightly more lenient rather than harming the player._

## science-nature · buried · `0d64947b`

**Originál (v prode):** V roku 1868 astronómovia počas zatmenia zbadali v slnečnom svetle neznámy prvok — 27 rokov predtým, než ho ktokoľvek našiel na Zemi. Ktorý prvok to je, príznačne pomenovaný po gréckom bohu Slnka?
Odpoveď: Hélium

**retranslate** (**8.0/10**)
V roku 1868 astronómovia počas zatmenia zbadali v slnečnom svetle neznámy prvok — 27 rokov predtým, než ho ktokoľvek našiel na Zemi. Príhodne ho pomenovali podľa gréckeho boha slnka. O ktorý prvok ide?
_brána: čistá_

**rewrite** (**10.0/10**)
V roku 1868 astronómovia počas zatmenia zbadali v slnečnom svetle neznámy prvok — 27 rokov predtým, než ho ktokoľvek našiel na Zemi. Príznačne ho pomenovali po gréckom bohu Slnka. Ktorý prvok to je?
_brána: čistá_

## sports-mix · buried · `0f015294`

**Originál (v prode):** Líder Tour de France nosí žltý dres. Farba nebola zvolená kvôli viditeľnosti – od čoho bola odkopírovaná?
Odpoveď: Od papiera novín, ktoré preteky organizovali

**retranslate** (nehodnotené)
Líder Tour de France nosí žltý dres. Táto farba nebola zvolená kvôli viditeľnosti – bola prevzatá odinakiaľ. Odkiaľ pochádzala?
Odpoveď zmenená: Z papiera novín, ktoré preteky organizovali
_brána: čistá_

**rewrite** (**10.0/10**)
Líder Tour de France nosí žltý dres. Farba nebola zvolená kvôli viditeľnosti. Od čoho bola odkopírovaná?
_brána: čistá_

## history · buried · `1ae3dd75`

**Originál (v prode):** Klinové písmo, najstarší známy systém písma na svete, nevzniklo preto, aby zaznamenávalo modlitby, básne či skutky kráľov. Najstaršie hlinené tabuľky zo sumerského mesta Uruk ukazujú, že vzniklo na oveľa všednejší účel — čo si teda ľudia v skutočnosti zapisovali?
Odpoveď: Účtovné záznamy

**retranslate** (**9.0/10**)
Klinové písmo, najstarší známy systém písma na svete, nevzniklo na zaznamenávanie modlitieb, básní ani činov kráľov. Najstaršie hlinené tabuľky zo sumerského mesta Uruk ukazujú, že vzniklo na oveľa všednejší účel. Čo si teda ľudia v skutočnosti zapisovali?
_brána: čistá_

**rewrite** (**10.0/10**)
Klinové písmo, najstarší známy systém písma na svete, nevzniklo preto, aby zaznamenávalo modlitby, básne či skutky kráľov. Najstaršie hlinené tabuľky zo sumerského mesta Uruk ukazujú, že vzniklo na oveľa všednejší účel. Čo si teda ľudia v skutočnosti zapisovali?
_brána: čistá_

## entertainment · buried · `32a211d7`

**Originál (v prode):** Festival v Glastonbury sa v lete 2026 konal ako zvyčajne. Pravda alebo nepravda?
Odpoveď: Nepravda

**retranslate** (**6.0/10**) — velmi divna otazka sama o sebe. nejak nedava zmysel celkovo. neviem posudit ako ohodnotit samotny preklad, takze hodnotit celkove znenie a zmysel.
Festival v Glastonbury sa v lete 2026 konal ako zvyčajne. Je to pravda, alebo nepravda?
_brána: čistá_

**rewrite** (**10.0/10**)
Festival v Glastonbury sa v lete 2026 konal ako zvyčajne. Je to pravda alebo nepravda?
_brána: čistá_

## entertainment · buried · `41b7bf47`

**Originál (v prode):** Seriál Star Wars: Shadow Lord z roku 2026 na Disney Plus je postavený okolo ktorého klasického záporáka?
Odpoveď: Darth Maul

**retranslate** (**9.0/10**)
Okolo ktorého klasického záporáka je postavený seriál Star Wars: Shadow Lord, ktorý vyšiel v roku 2026 na Disney Plus?
_brána: čistá_

**rewrite** (**10.0/10**)
Seriál Star Wars: Shadow Lord z roku 2026 na Disney Plus je postavený okolo jedného klasického záporáka. Ktorý je to?
_brána: čistá_

## geography-world · buried · `50f7966d`

**Originál (v prode):** Ktorá havajská sopka je meraná od základne na morskom dne po vrchol vyššia ako Mount Everest?
Odpoveď: Mauna Kea

**retranslate** (**7.0/10**) — nasilu vlozena opytovacia spojka "ktora" mam pocit. lepsie by napriklad znelo "havajská sopka meraná od svojej základne na dne oceánu až po vrchol je vyššia ako Mount Everest. ktora?"
takze nasilu by som nedaval opytovacie zameno (slovo) na zaciatok za kazdu cenu.
Ktorá havajská sopka je meraná od svojej základne na dne oceánu až po vrchol vyššia ako Mount Everest?
_brána: čistá_

**rewrite** (**9.0/10**)
Ak sa meria od základne na morskom dne po vrchol, je jedna havajská sopka vyššia ako Mount Everest. Ktorá sopka to je?
_brána: čistá_

## sports · buried · `596b8d29`

**Originál (v prode):** Ktorá krajina s piatimi titulmi vyhrala mužské futbalové majstrovstvá sveta viackrát než ktorákoľvek iná?
Odpoveď: Brazília

**retranslate** (**8.0/10**) — "Ktorá krajina s piatimi titulmi..." tato cast je taka komplikujuca by som povedal. otazka sa pyta na krajinu, ale je zneprehladnena este tymi dalsimi vyjasnujucimi slovami. neviem povedat ako ju lepsie zostavit. mozno rozdelit na uvodnu oznamovaciu vetu a druha veta by bola samotna otazka.
Ktorá krajina s piatimi titulmi vyhrala majstrovstvá sveta vo futbale mužov viackrát než ktorákoľvek iná?
_brána: čistá_

**rewrite** (**10.0/10**)
Jedna krajina vyhrala mužské futbalové majstrovstvá sveta päťkrát, teda viackrát než ktorákoľvek iná. Ktorá krajina to je?
_brána: čistá_

## general · buried · `7b908edd`

**Originál (v prode):** Ktorému svetoznámemu fyzikovi ponúkli v roku 1952 post prezidenta Izraela, ktorý však zdvorilo odmietol?
Odpoveď: Albert Einstein

**retranslate** (**10.0/10**)
V roku 1952 ponúkli jednému svetoznámemu fyzikovi funkciu prezidenta Izraela, ktorú zdvorilo odmietol. Ktorý fyzik to bol?
_brána: judge: major related_language_interference — "jednanie" is a Czech form/bohemism; standard Slovak would use "zaobchádzanie s ľuďmi" or "rokovanie s ľuďmi", though the item remains playable and gradable._

**rewrite** (**10.0/10**)
V roku 1952 ponúkli post prezidenta Izraela svetoznámemu fyzikovi, ktorý ponuku zdvorilo odmietol. Ktorý fyzik to bol?
_brána: judge: major related_language_interference — "jednanie" is a Czechism; Slovak uses "zaobchádzanie/styk s ľuďmi", so a native speaker would hear the explanation as non-Slovak.; major fluency_grammar — Subject–verb agreement error: plural "vlohy" requires "chýbajú" (or singular "chýba vloha"), making the sentence ungrammatical when read aloud._

## general · control · `9a98eab9`

**Originál (v prode):** Ktorý kontinent má viac zvrchovaných štátov než ktorýkoľvek iný?
Odpoveď: Afrika

**retranslate** (**10.0/10**)
Ktorý kontinent má viac zvrchovaných štátov než ktorýkoľvek iný?
_brána: čistá_

**rewrite** (**10.0/10**)
Ktorý kontinent má viac zvrchovaných štátov než ktorýkoľvek iný?
_brána: čistá_

## movies-music · buried · `aaf1fee9`

**Originál (v prode):** Do roku 2024 nazbieral filmový vesmír Marvel rekordných štrnásť nominácií na Oscara v jedinej kategórii bez toho, aby ju kedykoľvek vyhral — o ktorú kategóriu ide?
Odpoveď: Najlepšie vizuálne efekty

**retranslate** (**10.0/10**)
Do roku 2024 nazbieral filmový vesmír Marvel rekordných štrnásť nominácií na Oscara v jedinej kategórii bez toho, aby ju čo i len raz vyhral. O ktorú kategóriu ide?
_brána: čistá_

**rewrite** (**10.0/10**)
Do roku 2024 nazbieral filmový vesmír Marvel rekordných štrnásť nominácií na Oscara v jedinej kategórii bez toho, aby ju kedykoľvek vyhral. O ktorú kategóriu ide?
_brána: judge: major lexical_calque — English "ever" is rendered literally as "kedykoľvek" (= "at any time you like"), which a native would correct to "niekedy"/"a nikdy ju nevyhral"; the item is still playable and gradable._

## movies-music · buried · `ab505aa0`

**Originál (v prode):** Na Oscaroch 2026 získal Michael B. Jordan cenu za najlepší mužský herecký výkon v hlavnej úlohe za vampírsky hit Hriešnici (Sinners) — a Oscara za scenár k tomuto filmu si odniesol ktorý režisér, jeho dlhoročný spolupracovník z filmov Creed a Black Panther?
Odpoveď: Ryan Coogler

**retranslate** (**10.0/10**)
Na Oscaroch 2026 získal Michael B. Jordan cenu za najlepší mužský herecký výkon v hlavnej úlohe za upírsky hit Sinners. Oscara za scenár k tomuto filmu si odniesol jeho dlhoročný spolupracovník z filmov Creed a Black Panther. Ktorý režisér to bol?
_brána: čistá_

**rewrite** (**9.0/10**)
Na Oscaroch 2026 získal Michael B. Jordan cenu za najlepší mužský herecký výkon v hlavnej úlohe za vampírsky hit Hriešnici (Sinners). Ktorý režisér, jeho dlhoročný spolupracovník z filmov Creed a Black Panther, si odniesol Oscara za scenár k tomuto filmu?
_brána: judge: minor lexical_calque — Slovak normally says "upírsky" (from "upír"); "vampírsky" is the less native variant, though it is fully understandable and does not affect answering or grading._

## movies-music · control · `b23b6cc5`

**Originál (v prode):** Ktoré režisérske duo prešlo od radostne absurdného filmu Lego príbeh k vesmírnemu trháku Project Hail Mary z roku 2026 s Ryanom Goslingom?
Odpoveď: Phil Lord a Christopher Miller

**retranslate** (**9.0/10**)
Ktorá režisérska dvojica prešla od rozjašene absurdného Lego príbehu k vesmírnemu trháku Project Hail Mary z roku 2026 s Ryanom Goslingom?
_brána: čistá_

**rewrite** (**9.0/10**)
Ktoré režisérske duo prešlo od radostne absurdného filmu Lego príbeh k vesmírnemu trháku Project Hail Mary z roku 2026 s Ryanom Goslingom?
_brána: judge: minor other — Two single-name entries were added to the alternative answers that are not in the source, so a player naming only one half of the duo is graded correct even though the question asks for a duo._

## science-nature · buried · `cb0d1669`

**Originál (v prode):** Pravda alebo lož: Albert Einstein preslávene prepadol z matematiky, keď bol školák.
Odpoveď: Lož

**retranslate** (**10.0/10**)
Pravda alebo lož: Albert Einstein v školských časoch preslávene prepadol z matematiky.
Odpoveď zmenená: b
_brána: guard: number_mismatch(missing=11;added=-) | judge: major lexical_calque — The English adverb "famously" is carried over word-for-word; Slovak "preslávene" means "in a glorious manner" and does not carry the "as is well known" sense, so a native would write "ako je známe" or drop it — the claim is still understandable and gradable._

**rewrite** (**10.0/10**)
O Albertovi Einsteinovi sa traduje, že ako školák prepadol z matematiky. Je to pravda, alebo lož?
_brána: čistá_

## food-everyday · control · `e0ed8486`

**Originál (v prode):** V roku 1940 vojnové embargo odrezalo nemeckú továreň Coca-Coly od amerického sirupu, a tak jej chemici vytvorili novú ovocnú limonádu z miestnych zvyškov, ako sú jablkové výlisky a srvátka. Ktorá značka, ktorá sa dodnes predáva po celom svete, takto vznikla?
Odpoveď: Fanta

**retranslate** (**9.0/10**)
V roku 1940 vojnové embargo odrezalo nemeckú továreň Coca-Coly od amerického sirupu, a tak jej chemici vytvorili novú ovocnú limonádu z miestnych zvyškov, ako boli jablčné výlisky a srvátka. Ktorá značka, ktorá sa dodnes predáva po celom svete, takto vznikla?
_brána: čistá_

**rewrite** (**9.0/10**)
V roku 1940 vojnové embargo odrezalo nemeckú továreň Coca-Coly od amerického sirupu, a tak jej chemici vytvorili novú ovocnú limonádu z miestnych zvyškov, ako sú jablkové výlisky a srvátka. Ktorá značka, ktorá sa dodnes predáva po celom svete, takto vznikla?
_brána: judge: minor lexical_calque — Added alternative answer uses "oranžová" (the colour) where Slovak names the flavour "pomarančová" (as the explanation itself does), and it denotes the 1955 orange variant rather than the brand asked about; grading is unaffected since the key answer "Fanta" is intact._

## sports · control · `feeaea25`

**Originál (v prode):** Keď Nadia Comăneciová v roku 1976 získala ako prvá v olympijskej gymnastike perfektnú desiatku, na svetelnej tabuli v hale sa preslávene ukázalo iné číslo. Ktoré?
Odpoveď: 1,00

**retranslate** (**10.0/10**)
Keď Nadia Comăneciová v roku 1976 získala ako prvá v dejinách olympijskej gymnastiky perfektnú desiatku, svetelná tabuľa v hale ukázala známym spôsobom iné číslo. Aké číslo sa na nej objavilo?
Odpoveď zmenená: 1.00
_brána: judge: major idiom_calque — English "famously showed" is rendered word-for-word as "in a known manner", which is not idiomatic Slovak and shifts the meaning; a native would write "ako je známe, ukázala iné číslo"._

**rewrite** (**10.0/10**)
Keď Nadia Comăneciová v roku 1976 získala ako prvá v olympijskej gymnastike perfektnú desiatku, na svetelnej tabuli v hale sa preslávene ukázalo iné číslo. Aké číslo to bolo?
_brána: judge: minor lexical_calque — English sentence adverb "famously" rendered word-for-word as "preslávene", which is not idiomatic Slovak here; a native would say e.g. "sa objavilo iné, dnes už povestné číslo" — the item remains fully playable and gradable._

