# #223 — Stránky s kvízovými otázkami na trubbo.app

**Triage:** enhancement · ready-for-agent
**Založené:** 2026-11-02 (founder: „pusti sa do nich“; témy: „1 sa zdá byť ok“; „nikde moc nepromujeme čerstvé entertainment otázky“)
**Súvisí:** rešerš blogu (artefakt `docs/artifacts/blog-research/`, verdikt: blog nie, stránky s otázkami áno), refresh webu PR #677 #679, #202 (týždenná čerstvá zábava), #210 (App Store odkazy s kampaňou)

## Cieľ a kedy je hotovo
Ľudia, ktorí hľadajú „kvízové otázky do auta / na oslavu / o Slovensku“, nájdu na trubbo.app hrateľné stránky s overenými otázkami a odkazom do App Store.
**Hotovo** = 10 tém sk + 10 cs + rozcestník naživo, v sitemape, s odkazmi z hlavnej stránky; App Store odkazy s kampaňou `web_<lang>_<téma>`; čerstvá zábava sa obnovuje sama každý týždeň.

## Rozhodnutia foundera (2026-11-02)
- Témy: do auta, pre celú rodinu, o Slovensku / o Česku, filmy a seriály, hudba, šport, jedlo, príroda + zvieratá + vesmír, dejiny, zemepis a cestovanie.
- 20 otázok na stránku, odpoveď až po ťuknutí, pod ňou príbeh a zdroj; na konci App Store.
- Čerstvé otázky zo zábavy treba propagovať → 11. téma, obnovovaná týždenne.

## Kroky
- **223.1** Snapshot schválených sk/cs otázok z produ (len čítanie: approved, bez balíkov, neexpirované, text, so zdrojom a vysvetlením, bez `adults`). Výber 20 na tému, bez opakovania v jazyku, len nadčasové otázky (žiadne „v roku 2026“), bez aktuálnej politiky a vojen, bez pomlčiek v texte.
- **223.2** Generátor stránok v `apps/website/build.py`: `/sk/otazky/<téma>/`, `/cs/otazky/<téma>/`, rozcestník `/sk/otazky/`; vzhľad F, schema.org `Quiz`, hreflang sk↔cs, sitemap, odkaz z hlavnej stránky a päty.
- **223.3** Čerstvá zábava: stránka `/sk/otazky/cerstve/` (+ cs, en) s najnovšími otázkami s aktívnym zvýhodnením (`boost_until`), obnovovaná po týždennom behu `fresh-topup.yml` cez automatický PR; na hlavnej stránke odkaz „Nové otázky tento týždeň“.
- **223.4** EN témy neskôr; vyhodnotenie po ~6 mesiacoch podľa stiahnutí z kampaní `web_*` v App Store Connect, bez výsledku ďalej nerozširovať.

## Riziká
- Otázky na webe ostávajú aj v appke: hráč, ktorý ich čítal, ich môže dostať znova. Pri ~200 z ~750 na jazyk prijateľné, sledovať.
- Snapshot zastará len pri archivácii otázky; obnoviť pri ďalšom behu exportu.
