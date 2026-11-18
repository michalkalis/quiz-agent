# Verzie appky, údržba a správy v appke: čo mať pred prvým vydaním (2026-10-28)

Rešerš k #214 — odporúčaná aktualizácia a režim údržby. Otázka: čo musí byť v binárke, aby sme neskôr zvládli zmeny backendu, výpadky a nové verzie bez ďalšieho vydania.

## Zistenia (so zdrojmi)

- **Tvrdé minimum + odporúčaná verzia z vlastnej konfigurácie** je štandard (minimálna verzia blokuje, odporúčaná sa dá zavrieť), porovnávať číselne, nie ako text. https://firebase.google.com/docs/remote-config/use-cases/minimum-version
- **iTunes Lookup API mešká** (CDN cache, aj deň), na tvrdé minimum sa nehodí. https://developer.apple.com/forums/thread/725780 · Siren preto čaká 1 deň a pri postupnom vydaní odporúča 7 dní. https://github.com/ArtSabintsev/Siren
- **Postupné vydanie** trvá 7 dní a týka sa len automatických aktualizácií; ručne si hráč stiahne novú verziu hneď. Minimum zvyšovať až po dostupnosti v obchode. https://developer.apple.com/help/app-store-connect/update-your-app/release-a-version-update-in-phases/
- **App Review:** blokujúca obrazovka aktualizácie nie je zakázaná; odkaz má viesť priamo na stránku appky. Text a prepínače zo servera sú dáta, nie kód (2.5.2), nesmú odomykať skryté funkcie. https://developer.apple.com/app-store/review/guidelines/
- **Konfigurácia mimo hlavného servera** (statický JSON na R2 s vlastnou doménou) + posledná známa kópia v telefóne = správa sa dostane aj počas výpadku. https://developers.cloudflare.com/r2/buckets/public-buckets/
- **Hlavičky Deprecation (RFC 9745) a Sunset (RFC 8594)** sú len na strane servera, dajú sa pridať kedykoľvek. https://www.rfc-editor.org/rfc/rfc9745.html · https://www.rfc-editor.org/rfc/rfc8594.html

## Stav Trubbo pred #214

Už máme: vynútenú aktualizáciu (#193.9, App Store aj TestFlight minimum, overené aj pre App Store variant #209), oznam na Home, vypínač objednávok, prepínače bez reštartu (#207.18), verziu appky v hlavičke každej požiadavky, CI kontrolu kompatibility API voči živým buildom (#207.26), opakovanie pri krátkom výpadku (#193.12).

Kľúčové: vynútená aktualizácia je v 1.1, takže čokoľvek ďalšie môže prísť v ďalšej verzii; 1.1 sa v prípade potreby posunie na novú verziu.

## Rozhodnutie foundera (2026-10-28)

- Do ďalšej verzie, 1.1 ostáva v review.
- Áno: odporúčaná aktualizácia (karta na Home), režim údržby (celá obrazovka).
- Teraz nie: správy počas úplného výpadku (záloha mimo servera), bohatšie oznamy (odkaz, závažnosť, cielenie na verzie), odmietnutie starej verzie pri ľubovoľnej požiadavke.
