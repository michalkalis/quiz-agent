# #223 — Stránky s kvízovými otázkami na trubbo.app

**Triage:** enhancement · ready-for-agent (223.1–223.3 hotové 2026-11-02; ostáva 223.4)
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
- **223.1** ✅ PR #687 (2026-11-02). Snapshot schválených sk/cs otázok z produ (len čítanie: approved, bez balíkov, neexpirované, text, so zdrojom a vysvetlením, bez `adults`). Výber 20 na tému, bez opakovania v jazyku, len nadčasové otázky (žiadne „v roku 2026“), bez aktuálnej politiky a vojen, bez pomlčiek v texte.
- **223.2** ✅ PR #687. Generátor stránok v `apps/website/build.py`: `/sk/otazky/<téma>/`, `/cs/otazky/<téma>/`, rozcestník `/sk/otazky/`; vzhľad F, schema.org `Quiz`, hreflang sk↔cs, sitemap, odkaz z hlavnej stránky a päty.
- **223.3** ✅ PR #688 #689 #690 (2026-11-02, backend nasadený). Čerstvá zábava: `/sk/otazky/cerstve/` + cs s najnovšími otázkami s aktívnym zvýhodnením (`boost_until`); verejné API `GET /api/v1/public/fresh-questions` (quiz-agent), web si ich načíta pri každom nasadení a denne o 06:40 UTC (`website.yml`), pri výpadku ostáva uložená verzia; na hlavnej sk/cs stránke odkaz „Nové otázky z tohto týždňa“. EN čerstvé až s 223.4.
- **223.4** EN témy neskôr; vyhodnotenie po ~6 mesiacoch podľa stiahnutí z kampaní `web_*` v App Store Connect, bez výsledku ďalej nerozširovať.

## Riziká
- Otázky na webe ostávajú aj v appke: hráč, ktorý ich čítal, ich môže dostať znova. Pri ~200 z ~750 na jazyk prijateľné, sledovať.
- Snapshot zastará len pri archivácii otázky; obnoviť pri ďalšom behu exportu.

## Poznámky
- `api.trubbo.app` do prepnutia #222 (presun backendu na Hetzner) vedie na skúšobný Hetzner bez endpointu; web skúša aj Fly (PR #690). Po prepnutí overiť, že `api.trubbo.app` vracia otázky.
