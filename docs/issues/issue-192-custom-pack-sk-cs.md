# #192 — Vlastné balíky v slovenčine a češtine (natívne generovanie)

**Triage:** enhancement · in-progress
**Založené:** 2026-10-07 (founder: „vlastné balíky v slovenčine a češtine“)
**Nadväzuje na:** TODO „Custom packy: natívne generovanie v jazyku promptu“ (founder 2026-09-01, pri príprave #168 — batch preklad SK/CS, DD15)

## Rozhodnutia foundera (2026-10-07)

- Jazyk balíka sa **vyberá vo formulári** objednávky (sk / cs / en), predvolený = jazyk kvízu z nastavení. Detekcia jazyka zo zadania zamietnutá ako zbytočne zložitá.
- Ak zákazník napíše zadanie v inom jazyku, otázky sa aj tak vygenerujú vo **zvolenom** jazyku (generovanie dostane pokyn „zadanie môže byť v hocijakom jazyku, píš v X“), bez samostatného prekladového kroku.
- Ponúkajú sa len aktuálne podporované jazyky (en, sk, cs).

## Nález pri príprave

Text zadania zákazníka sa pri predvolenom priamom generovaní (#166 D21b) **vôbec nedostal** ku generovaniu otázok (#42, príčina D). Appka od #138 neposiela kategóriu ani tému, takže platený „vlastný“ balík bol v praxi všeobecný kvíz. Opravené v tracku A, platí to aj pre anglické balíky.

## Tracky

### A — Server: generovanie (quiz-pack-api) · HOTOVÉ v kóde
- Do každého generovacieho promptu sa pridáva zadanie zákazníka (ako dáta, nie ako inštrukcie) a pre sk/cs aj sekcia s výstupným jazykom (natívne písanie, žiadne kalky, žiadne české/slovenské tvary navzájom, originálne názvy diel, Pravda/Nepravda). Anglický beh bez zadania (korpus/CLI) má prompt bez zmeny.
- Deterministické kontroly čítajú slová s diakritikou celé (stem leak, dedup, kompozícia, answerability), Pravda/Nepravda sa ráta ako T/F, „pretože/lebo/protože“ ako chvost odpovede. Answerability model odpovedá v jazyku otázky.
- `PACK_ORDER_LANGUAGES` predvolene `en,sk,cs`.

### B — Server: hranie (quiz-agent) · HOTOVÉ v kóde
- Session balíka má vždy jazyk balíka (nie jazyk z appky).
- Otázka v jazyku session sa neprekladá (žiadne LLM „sk → sk“), TF štítok ukazuje jej vlastný jazyk.
- Pri balíkoch sa nevyraďujú `language_dependent` otázky (natívna slovná hra patrí do svojho jazyka).

### C — iOS · TODO
- Hlasové povely a rozpoznávanie reči sa riadia jazykom session (`currentSession.language`), nie nastavením appky (`VoiceCommandCoordinator` `commandLanguage`, `AudioDeviceState` command engine).
- Formulár sa nemení: zoznam jazykov už ide zo servera (`GET /api/v1/languages`).

### D — Overenie · TODO
- Skúšobný sk a cs balík cez CLI `generate_pack.py --language sk --prompt …` (dry-run) → founder posúdi kvalitu otázok.
- Po deployi e2e objednávka v TF (na požiadanie).

## Známe obmedzenia (vedome mimo rozsahu)
- `tier_router` (smerovanie fact-checku podľa „najnovší/rekord“) má len anglické výrazy — platí len pri zapnutom tier routingu.
- Kritik / porota (best-of-N, `JUDGE_GATE`) majú anglické prompty; v predvolenom nastavení sú vypnuté.
- Uzemnený režim (`DIRECT_GENERATION=0`) zdrojuje fakty z anglickej Wikipédie.
