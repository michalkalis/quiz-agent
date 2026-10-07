# #192 — Vlastné balíky v slovenčine a češtine (natívne generovanie)

**Triage:** enhancement · ready-for-human
**Založené:** 2026-10-07 (founder: „vlastné balíky v slovenčine a češtine“)
**Nadväzuje na:** TODO „Custom packy: natívne generovanie v jazyku promptu“ (founder 2026-09-01, pri príprave #168 — batch preklad SK/CS, DD15)

## Rozhodnutia foundera (2026-10-07)

- Jazyk balíka sa **vyberá vo formulári** objednávky (sk / cs / en), predvolený = jazyk kvízu z nastavení. Detekcia jazyka zo zadania zamietnutá ako zbytočne zložitá.
- Ak zákazník napíše zadanie v inom jazyku, otázky sa aj tak vygenerujú vo **zvolenom** jazyku (generovanie dostane pokyn „zadanie môže byť v hocijakom jazyku, píš v X“), bez samostatného prekladového kroku.
- Ponúkajú sa len aktuálne podporované jazyky (en, sk, cs).

## Nález pri príprave

Text zadania zákazníka sa pri predvolenom priamom generovaní (#166 D21b) **vôbec nedostal** ku generovaniu otázok (#42, príčina D). Appka od #138 neposiela kategóriu ani tému, takže platený „vlastný“ balík bol v praxi všeobecný kvíz. Opravené v tracku A, platí to aj pre anglické balíky.

## Tracky

### A — Server: generovanie (quiz-pack-api) · HOTOVÉ v kóde (PR #247)
- Do každého generovacieho promptu sa pridáva zadanie zákazníka (ako dáta, nie ako inštrukcie) a pre sk/cs aj sekcia s výstupným jazykom (natívne písanie, žiadne kalky, žiadne české/slovenské tvary navzájom, originálne názvy diel, Pravda/Nepravda). Anglický beh bez zadania (korpus/CLI) má prompt bez zmeny.
- Deterministické kontroly čítajú slová s diakritikou celé (stem leak, dedup, kompozícia, answerability), Pravda/Nepravda sa ráta ako T/F, „pretože/lebo/protože“ ako chvost odpovede. Answerability model odpovedá v jazyku otázky.
- Dávky dopĺňania dostanú zoznam otázok, ktoré už v balíku sú (nepýtať sa na ten istý fakt z iného uhla).
- Answerability pre sk/cs akceptuje iný gramatický tvar odpovede (stem matcher z #168).
- `PACK_ORDER_LANGUAGES` predvolene `en,sk,cs`.

### B — Server: hranie (quiz-agent) · HOTOVÉ v kóde
- Session balíka má vždy jazyk balíka (nie jazyk z appky).
- Otázka v jazyku session sa neprekladá (žiadne LLM „sk → sk“), TF štítok ukazuje jej vlastný jazyk.
- Pri balíkoch sa nevyraďujú `language_dependent` otázky (natívna slovná hra patrí do svojho jazyka).

### C — iOS · HOTOVÉ v kóde (PR #249)
- Hlasové povely a rozpoznávanie reči sa riadia jazykom session (`currentSession.language`), nie nastavením appky (`VoiceCommandCoordinator` `commandLanguage`, `AudioDeviceState` command engine).
- Formulár sa nemení: zoznam jazykov už ide zo servera (`GET /api/v1/languages`).

### D — Overenie · ČIASTOČNE
- 2026-10-07 skúšobné balíky (dry-run, subscription, 10 otázok): sk „Slovenské hrady, zámky a povesti o nich“, cs zadanie po anglicky „Czech beer and the history of brewing“ → otázky natívne, k téme, cs správne v češtine.
- Prvý sk beh odhalil 2 chyby, opravené: (1) dávky dopĺňania nevedeli, čo už v balíku je → rovnaký fakt 2× z iného uhla (týka sa všetkých jazykov, vidno až pri úzkom zadaní); (2) kontrola zodpovedateľnosti vyhadzovala správne odpovede v inom tvare („Čachtická hrad“). Druhý sk beh: 9 rôznych otázok, vyradená 1/10 (predtým 5/10).
- 2026-10-07 nasadené: quiz-agent v125, quiz-pack-api v70 (`GET /api/v1/languages` → `pack_order` en/sk/cs).
- Zostáva (founder): posúdiť skúšobné otázky; TF build na požiadanie → objednať sk/cs balík. Session worker (`session_worker_local.sh start`, `docs/setup/session-worker-mba.md`) musí bežať z aktuálneho `main`, inak generuje starým kódom.

## Známe obmedzenia (vedome mimo rozsahu)
- `tier_router` (smerovanie fact-checku podľa „najnovší/rekord“) má len anglické výrazy — platí len pri zapnutom tier routingu.
- Kritik / porota (best-of-N, `JUDGE_GATE`) majú anglické prompty; v predvolenom nastavení sú vypnuté.
- Uzemnený režim (`DIRECT_GENERATION=0`) zdrojuje fakty z anglickej Wikipédie.
