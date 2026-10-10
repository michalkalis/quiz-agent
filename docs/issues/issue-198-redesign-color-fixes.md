# #198 — Redizajn: vrátiť farby (čierne karty, vejár všade)

**Triage:** bug · ready
**Založené:** 2026-10-10 (founder po prezretí #194 — redizajn „Sklo nad kartami“: „karty otázok čierne, kategória adults, vejáre čierne/šedé všade, farby chýbajú, nedodržal si návrh“)

## Zistenia (recon origin/main 30f2b6f2)

- Karta otázky sa farbí podľa kategórie; **neznáma kategória → `default:` = ink** (čierna aj vo svetlom režime) a čip ukáže surové id (ADULTS, GENERAL).
- „adults“ = DEBUG fixtúry (`Question.preview*`), nie prod. **Prod: 213 approved + 117 pending_review otázok má stále „general“**, plus approved `kids` 1, `football` 1, `sports-mix` 2 → v hre bez zvolenej kategórie čierne karty.
- Oproti plátnu (smer Bg, aj tmavý režim) chýba farba: správna odpoveď (mätová karta), zlá odpoveď (karta vo farbe kategórie), počúvanie (ružový pás + Stop), koniec kola a prehľad odpovedí (farebné karty, ružovo/mätové riadky), prihlásenie (farebný vejár), plán na domove (kobaltový pruh), chyba (čierna karta).
- Logo (`TrubboMark`) v hlavičke každej nie-kvízovej obrazovky, na 34 pt sa číta ako čierny otáznik. `PackMiniDeck` (Moje balíčky, stav objednávky) = čierny vejár.

## Rozhodnutia foundera (2026-10-10)

- Hlavné tlačidlá **ostávajú čierne** (ink) ako v návrhu.
- Logo v hlavičke **len na domove a v sprievodcovi**; inde hlavička bez loga.
- Vlastné balíčky: **každý balíček svoju farbu** z palety kategórií (deterministicky z id balíčka, bez zmeny backendu).

## Tracky

- [x] **198.1 — HOTOVÉ 2026-10-10 (PR #350 dáta 342 riadkov, PR #351 appka) — kategórie v dátach:** prod otázky `general` / `kids` / `football` / `sports-mix` (approved + pending_review) zatriediť do 7 platných kategórií (`set-category` endpoint, zoznam zmien uložiť do `docs/testing/runs/`); obsah otázok sa nemení. DEBUG fixtúry na platné kategórie. Neznáma kategória v appke → kobalt (`accentPrimary`) namiesto ink, čip → zobrazovací názov alebo nič.
- [x] **198.2 — HOTOVÉ 2026-10-10 (PR #353) — farby z plátna do kvízu a výsledkov:** správna = mätová karta, zlá = karta vo farbe kategórie, počúvanie ružové, koniec kola + prehľad odpovedí farebné podľa plátna, plán na domove kobaltový, prihlásenie s farebným vejárom, chybová obrazovka bez čiernej karty. Svetlý aj tmavý režim; nerozbiť obsahové rozloženia z bety (MCQ, jednoriadkové texty).
- [x] **198.3 — HOTOVÉ 2026-10-10 (PR #353) — logo a vejár:** hlavička s logom len domov + sprievodca; vejár len domov, sprievodca, predplatné, prihlásenie.
- [x] **198.4 — HOTOVÉ 2026-10-10 (PR #351) — farba balíčka:** vlastný balíček dostane farbu z palety podľa id → karta otázky, `PackMiniDeck`, karty v Moje balíčky a stav objednávky.
- [~] **198.5 — pred/po:** stránka https://claude.ai/artifact/9LiXESfZkrxfZSy7ykypCo čaká na foundera; otvorené: koniec kola stále takmer bez farby, zlá odpoveď vo Vede = mätová ako správna. jedna stránka pred/po (svetlý + tmavý) s reálnymi kategóriami v snímkach → founder. kolo 2 HOTOVÉ 2026-10-11 (PR #360 koniec kola s farebnými kartami, chyba nikdy mätová; PR #356 An-225 archivovaná); founder: „lepšie o dosť“.

## Hotovo, keď

Žiadna čierna karta otázky/výsledku pri reálnych dátach; prod má 0 servovaných otázok mimo 7 kategórií; snímky pred/po schválené founderom.
