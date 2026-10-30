# #216 — Karty Hraj · Spolu · Profil po teste buildu 81

**Triage:** approved (founder 2026-10-30) · **Návrh:** https://claude.ai/artifact/MJPWTXepxHeGxxaLcggyjr

Founder otestoval TestFlight build 81 a vybral z variantov v návrhu: **B** (tri karty), **P2**
(veľké logo, ktoré sa pri rolovaní zmenší do hornej lišty; len natívne, inak bez loga), **S1**
(Profil s kartou mesiaca), náročnosť ostáva pomenovaná „Náhodná“. Sekcia MOJE BALÍKY na Hraj
sa vizuálne nemení.

Podklady: HIG Tab bars (karty sú navigácia, nie akcie; menej kariet; stále viditeľné), HIG
Branding (logo ustupuje obsahu), WWDC25 323 (`tabBarMinimizeBehavior(.onScrollDown)`).
P2 je natívne: `ToolbarItem(placement: .largeTitle)` (iOS 26) pre veľké logo a `.title` pre malé
logo v lište; prechod pri rolovaní robí systém (Apple docs ToolbarItemPlacement).

## Úlohy

- [ ] **216.1 Náročnosť predvolene Náhodná** — `QuizSettings.default` + `Config.defaultDifficulty`
  → `random` (server vyberá náročnosť pre každú otázku zvlášť, `question_retriever._determine_difficulty`).
  Jednorazový prechod: uložené `medium` → `random` raz na zariadení (predpoklad: nikto si Strednú
  vedome nevybral; dnes sa to rozlíšiť nedá). Test: nové nastavenia = random; staré medium sa
  prepne raz, iná voľba ostane.
- [ ] **216.2 Karta Spolu + obrazovka Hraj**
  - Tretia karta „Spolu“ (`person.2`) medzi Hraj a Profil, len keď je serverový prepínač
    `multiplayer_enabled` zapnutý (obchodná verzia bez neho kartu nemá).
  - Obsah karty = dnešná úvodná obrazovka hry spolu (hry v tejto Wi‑Fi, Založ hru, QR rada).
    Hľadanie beží len kým je karta na obrazovke. Po založení / pridaní sa hra otvorí cez celú
    obrazovku ako dnes (RoomFlowView); zatvorenie vráti na kartu.
  - Tlačidlo „Spolu“ z Hraj preč. Pozvánka odkazom / QR funguje ako dnes.
  - Hraj: logo ako veľký nadpis v navigačnej lište (P2), pri rolovaní malé logo; žiadny pevný
    riadok s logom. Štart ostáva dole, ale ako lišta nad obsahom (`safeAreaBar`), obsah pod ním
    presvitá so systémovým efektom okraja.
  - Lišta s kartami sa pri rolovaní dole zmenší (`tabBarMinimizeBehavior(.onScrollDown)`).
  - Meranie: udalosť `together_opened` pri otvorení karty (taxonómia + iOS v tom istom PR).
- [ ] **216.3 Profil S1 + plán**
  - Karta „tvoj plán“ z Hraj do Profilu (pod účet), rovnaké stavy a ťuky ako dnes.
  - Riadok „Moje balíky“ z Profilu preč (balíky ostávajú na Hraj a v Nastaveniach).
  - Najnovší prehľad (prvý / mesiac / rok) ako jedna karta s tromi číslami: celkom otázok,
    najsilnejšia kategória, kedy hráš; tlačidlo Zdieľaj vyrobí obrázok 9:16 tej istej karty.
    Bez prehľadu: karta „Tvoj prvý prehľad“ s postupom ako dnes.
  - „Všetky štatistiky ›“ otvorí zoznam ostatných kariet (kde hráš, typický kvíz, pokrok,
    najlepšia séria, najslabšia kategória). Zrušené zobrazenie: typ hráča, príbehový prehľad,
    ťažké otázky, možnosti vs. vlastné slová, najrýchlejšia kategória (server ich naďalej posiela;
    staré buildy ich používajú).
  - sk „Spolu“ (celkový počet) → „Celkom“, aby sa nebilo s kartou Spolu.
  - Meranie: `recap_shared` ostáva; `recap_viewed` sa z novej appky už neposiela.

## Poradie a riziká

216.1 → 216.2 → 216.3, každé samostatné PR (216.2 a 216.3 obe menia Hraj). Snímky Home,
Profil a prehľadu sa vedome nahrávajú nanovo. UI testy, ktoré ťukali na `home.together`,
idú cez kartu `tab.together`.
