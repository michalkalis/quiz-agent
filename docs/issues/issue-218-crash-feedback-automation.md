# #218 — Pády a spätná väzba automaticky do issues, rýchly alarm výpadku

**Triage:** enhancement · in-progress (beží od 2026-11-03, ostáva ostrý test z TestFlightu a skúšobná oprava) (founder rozhodnutia 2026-11-01 nižšie)
**Status:** 2026-11-01 founder: každý nový pád alebo problém v Sentry a každá spätná väzba z TestFlightu (screenshot aj pád) sa sama zmení na sledované GitHub issue s AI analýzou príčiny. Opravná PR vznikne až po súhlase foundera. K tomu rýchle zistenie výpadku.
**Súvisí:** #207 — pripravenosť na produkciu (207.7 alarmy e-mailom, 207.13 denné limity) · #193 — beta hardening (193.3 `prod-monitor`) · skill `/check-crashes` · in-app feedback (admin `GET /api/v1/feedback`)

## Cieľ

1. Žiadny pád ani hlásenie testera sa nestratí: každé má 1 issue s príčinou a návrhom opravy.
2. Rovnaký pád = 1 issue, pri ďalších výskytoch sa len zvýši počet.
3. Oprava až na povel foundera, potom bežný tok PR (review + CI).
4. Výpadok hrania vieme do ~3 min, nie až o ~4 h.
5. Jeden zlý deň ani jeden zneužitý účet neminie AI kredit bez stropu.

Hotovo, keď: skúšobný pád z TF buildu, skúšobná spätná väzba z TestFlightu a z appky skončia ako issue s analýzou (bez zásahu človeka), druhý výskyt toho istého pádu len zvýši počet, štítok od foundera otvorí opravnú PR, a Sentry uptime pri výpadku quiz-agentu pošle 1 mail.

## Čo už existuje (overené 2026-11-01)

- **Sentry** (plán Developer, zadarmo): uptime monitor na `quiz-agent-api` každú minútu z infraštruktúry Sentry (mimo Fly, pokryje aj pád celého regiónu cdg), cron monitor `pack-worker`. **Žiadne alert pravidlo** okrem predvoleného Seer pravidla: `scripts/sentry_monitoring.py` (uptime + nový pád → mail) je napísaný, ale nikdy nebol spustený s `--apply`, lebo chýba token `SENTRY_ALERTS_TOKEN`. Výpadok quiz-agentu teda dnes zachytí len vzájomný dozor na Fly (rovnaký región) a `prod-monitor`.
- **Objem:** 11 otvorených problémov za 14 dní (7 warning, 3 error, 1 outage). Prostredia: `production`, `staging`, `development`, `dsn-verification`.
- **Plán Developer nemá integrácie** (GitHub, webhooky, alert akcie do iných nástrojov) ani Seer; obe len od Team (26 $/mes.) a Seer navyše 40 $/prispievateľa/mes. ([sentry.io/pricing](https://sentry.io/pricing/), [docs](https://docs.sentry.io/pricing/)). REST API s naším tokenom funguje → udalosť z Sentry dostaneme len krátkym dotazom na API, nie webhookom.
- **App Store Connect API** (WWDC25): webhooky `BETA_FEEDBACK_SCREENSHOT_SUBMISSION_CREATED` a `BETA_FEEDBACK_CRASH_SUBMISSION_CREATED`, registrácia `POST /v1/webhooks`, test `POST /v1/webhookPings`, história `GET /v1/webhooks/{id}/deliveries`, podpis hlavička `x-apple-signature: hmacsha256=<hex>` (HMAC-SHA256 tela). Detail: `GET /v1/betaFeedbackScreenshotSubmissions/{id}`, `GET /v1/betaFeedbackCrashSubmissions/{id}` + `/crashLog`. Rola kľúča Admin / App Manager / Developer ([webhook-events](https://developer.apple.com/documentation/appstoreconnectapi/webhook-events), [configuring](https://developer.apple.com/documentation/appstoreconnectapi/configuring-webhook-notifications), [crash submissions](https://developer.apple.com/documentation/appstoreconnectapi/beta-feedback-crash-submissions)). Pozor: [vlákno vo fóre](https://origin-devforums.apple.com/forums/thread/832562) hlási zamrznutý príjem spätnej väzby pre jednu appku od 2026-05-31 (neoverené, overíme na našej appke v 218.5).
- **GitHub secrets:** `ASC_API_KEY_*`, `ASC_ADMIN_API_KEY_*`, `ASC_API_ISSUER_ID`, `SENTRY_AUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN` (review cez predplatné Max), `QUIZ_AGENT_ADMIN_API_KEY`. Repo `quiz-agent` je **verejné** (issues aj logy Actions vidí každý).
- **In-app spätná väzba:** `POST /api/v1/feedback` ukladá do Postgresu a do Sentry posiela len `feedback.received` (info); plný detail cez admin endpoint.
- **Limity nákladov (#207, 207.13):** na hráča za deň STT tokeny, sekundy nahrávky, pokusy na 1 otázku, synchronizácie; TTS znaky; globálny denný strop ElevenLabs s prechodom na záložný hlas; každú hodinu zostatky OpenRouter/ElevenLabs/Anthropic (kredit Max)/Fly, OpenAI mesačný rozpočet (čaká na admin kľúč). **Chýba:** globálny denný strop pre AI hodnotenie odpovedí (Claude Haiku 5.5 + záloha gpt-4o-mini) a strop počtu AI hodnotení na hráča za deň (Plus nemá mesačný limit otázok).
- **`prod-monitor`:** cron `7,37 * * * *`, GitHub ho reálne spúšťa ~raz za 4 h (207 riziká), komentár v súbore sľubuje ~1 h.

## Riešenie

**Udalosť → most → triáž → issue → súhlas → PR.**

- **Kde sú issues: súkromné repo `michalkalis/trubbo-triage`.** Spätná väzba testerov obsahuje screenshoty, mená a texty, pády zariadenia a build; vo verejnom repe by to videl každý, vrátane logov Actions. V súkromnom repe sú aj logy súkromné. Kód sa číta z verejného `quiz-agent`, opravné PR idú do `quiz-agent` ako dnes (bez osobných údajov v popise).
- **Most v quiz-agente** (jedno miesto pre GitHub token, beží na existujúcom stroji s výberom lídra, takže nič navyše):
  - *Sentry:* v existujúcom 5-min ops cykle dotaz na nové a vrátené problémy od posledného bodu (bod v Postgres). Len `production`, len `error` a horšie, bez kategórie outage (tú rieši alarm) a bez `feedback.received` (rieši ju vetva in-app). Nový/vrátený → `repository_dispatch` `sentry_new`; nové výskyty už známeho → `sentry_bump` najviac 1× za hodinu na problém. Nie je to nočný beh: odozva ≤ 5 min a bez nových udalostí sa nič nespúšťa.
  - *ASC:* nový endpoint `POST /api/v1/hooks/asc` overí `x-apple-signature`, vráti 200 hneď a pošle `asc_feedback` / `asc_crash` s ID.
  - *In-app:* `POST /feedback` po uložení pošle `app_feedback` s ID (na pozadí, chyba mostu nezdrží hráča).
- **Triáž (workflow v `trubbo-triage`):** stiahne detail (Sentry API / ASC API / admin feedback), screenshot uloží do repa (`attachments/`), **dedup**, potom `claude-code-action` (Opus 5.5, cez predplatné Max, obmedzený počet krokov, len čítanie kódu + `gh issue`) s inštrukciami z `/check-crashes`: príčina, dotknuté súbory, istota, návrh opravy, ktorí hráči a koľko. Issue dostane štítky `pád`/`spätná väzba`, `ios`/`backend`, `needs:founder`.
- **Dedup:** Sentry už pády zoskupuje → kľúč je ID problému Sentry (značka `sentry-issue:<id>` v tele). Bump = upraví riadok „Výskyty · hráči · buildy · naposledy“ bez AI; vrátený problém pri zatvorenom issue → znova otvoriť + komentár. Pád z TestFlightu sa spáruje s pádom v Sentry (rovnaký build, čas ±10 min) → komentár s textom testera do existujúceho issue. Hlásenie bez pádu: Claude dostane zoznam otvorených issues a buď napíše „duplikát #N“ (komentár tam, počet hlásení +1), alebo založí nové.
- **Súhlas:** founder pridá issue štítok `oprav` (alebo napíše `/oprav` s poznámkou). Workflow overí, že to urobil founder, Claude vytvorí vetvu `fix/<slug>` a PR do `quiz-agent` s odkazom na triáž. PR ide bežnou cestou (Claude review, CI, squash merge podľa `shared.md`). iOS oprava ide s najbližším TF buildom na povel foundera.
- **Alarm výpadku:** spustiť hotový `sentry_monitoring.py`: uptime (3 zlyhania za sebou ≈ 3 min) a cron `pack-worker` → mail. Pravidlo „nový pád → mail“ zúžiť na výpadky a backend, iOS pády chodia cez issues (inak 2 maily za to isté). `prod-monitor` ostáva ako záchranná sieť, bez nových služieb.
- **Zámerne nie:** Sentry Team + Seer (66 $+/mes.), externý uptime (UptimeRobot zadarmo len nekomerčne; cron-job.org by spúšťal `prod-monitor` presne, ale Sentry uptime už beží zadarmo mimo Fly), webhook z Sentry (plán ho nemá).

## Náklady (mesačne)

| Časť | Odhad |
|------|-------|
| Most na existujúcom stroji quiz-agent | 0 $ |
| GitHub Actions v súkromnom repe (2 000 min zadarmo; ~30 analýz × ~8 min + bumpy ~1 min) | 0 $ (~300–500 min) |
| Claude analýzy a opravy cez `CLAUDE_CODE_OAUTH_TOKEN` (predplatné Max, nie API kredit) | 0 $ |
| Sentry Developer, ASC webhooky | 0 $ |
| **Spolu** | **0 $** (nad prahom by bol len Sentry Team/Seer, nenavrhujeme) |

## Kroky

- [x] **218.1** Alarm výpadku zo Sentry. *Čo:* founder vytvorí token, agent spustí `sentry_monitoring.py` (najprv bez `--apply`, potom s ním), pravidlo zúži na výpadky a backend, opraví komentár v `prod-monitor.yml` (reálne ~4 h, záchranná sieť). *Prečo:* uptime už meria každú minútu mimo Fly, len nikomu nepíše. *Kto:* founder (token) → agent. *Hotovo:* pravidlo cez API existuje a je napojené na uptime aj cron monitor; žiadny skúšobný mail do founderovej schránky (overenie cez Sentry API a históriu). *Cena:* 0 $.
  Founder:
  1. Otvor https://missinghue.sentry.io/settings/account/api/auth-tokens/ (prihlásený ako hello@missinghue.com).
  2. Klikni **Create New Token**.
  3. Name: `trubbo-alerts`. V Scopes nastav **Project: Admin**, **Alerts: Read & Write**, **Issue & Event: Read**, ostatné nechaj tak.
  4. Klikni **Create Token** a token skopíruj (ukáže sa len raz).
  5. V repe `~/code/quiz-agent` otvor `.env`, pridaj riadok `SENTRY_ALERTS_TOKEN=` a za `=` vlož token. Ulož. Agentovi napíš len „hotovo“, token do chatu nedávaj.
- [x] **218.2** Súkromné triážne repo a prístupy. *Čo:* agent založí `trubbo-triage` (súkromné), štítky (`pád`, `spätná väzba`, `ios`, `backend`, `needs:founder`, `oprav`, `duplikát`), presunie do jeho secrets hodnoty z `.env` bez vypisovania (`SENTRY_AUTH_TOKEN`, ASC kľúč, admin kľúč quiz-agentu); founder vytvorí 2 tokeny a Claude token. *Prečo:* súkromné údaje testerov mimo verejného repa; PR vytvorená tokenom (nie `GITHUB_TOKEN`) spustí review a CI. *Kto:* agent + founder. *Hotovo:* `gh secret list -R michalkalis/trubbo-triage` ukazuje všetky mená, testovací `repository_dispatch` z Fly prejde (204). *Cena:* 0 $.
  Founder (agent repo založí vopred):
  1. Otvor https://github.com/settings/personal-access-tokens/new.
  2. Token name: `trubbo-triage-dispatch`. Expiration: najdlhšia ponúkaná možnosť. Resource owner: `michalkalis`.
  3. Repository access: **Only select repositories** → vyber `trubbo-triage`.
  4. Permissions → Repository permissions → **Contents: Read and write** (Metadata sa pridá sám). Klikni **Generate token**, skopíruj, do `.env` ako `GITHUB_TRIAGE_DISPATCH_TOKEN=`.
  5. Znova https://github.com/settings/personal-access-tokens/new. Name: `trubbo-triage-fix`, rovnaká Expiration, **Only select repositories** → `quiz-agent`. Permissions: **Contents: Read and write**, **Pull requests: Read and write**. **Generate token** → do `.env` ako `GITHUB_TRIAGE_FIX_TOKEN=`.
  6. V termináli spusti `claude setup-token`, prihlás sa v prehliadači, vypísaný token vlož do `.env` ako `CLAUDE_TRIAGE_OAUTH_TOKEN=`. Ulož `.env`, agentovi napíš „hotovo“.
  (Agent si zapíše dátum expirácie; most pri každom volaní číta hlavičku expirácie z GitHubu a 14 dní vopred to napíše do triážneho issue, nie mailom.)
- [x] **218.3** Most v quiz-agente. *Čo:* Sentry dotaz v ops cykle (bod v Postgres, filtre vyššie, bump ≤ 1×/h), `POST /api/v1/hooks/asc` s overením podpisu, dispatch z `POST /feedback`; Fly secrets `GITHUB_TRIAGE_DISPATCH_TOKEN`, `ASC_WEBHOOK_SECRET` (agent vygeneruje náhodne, nikam nevypisuje). *Prečo:* Sentry Developer nemá webhooky; jeden token na jednom mieste. *Kto:* agent. *Hotovo:* testy (zlý podpis = 401 bez dispatchu, ten istý problém Sentry nepošle 2× `sentry_new`, bump najviac 1×/h, výpadok GitHubu nezdrží `/feedback`, staging/development sa ignoruje), PR zlúčená, nasadené, prvý reálny dispatch v logu. *Cena:* 0 $.
- [x] **218.4** Triážny workflow s dedup a analýzou. *Čo:* `triage.yml` v `trubbo-triage` podľa sekcie Riešenie; bump bez Claude; analýza s limitom krokov a časom ≤ 15 min; text issue bez e-mailu testera (meno len iniciály). *Prečo:* jadro požiadavky. *Kto:* agent. *Hotovo:* na 3 skutočných otvorených problémoch zo Sentry vzniknú 3 issues s príčinou; opakovaný dispatch toho istého ID nevytvorí druhé issue; hlásenie zhodné s otvoreným issue skončí ako komentár. *Cena:* 0 $ (predplatné, minúty v limite).
- [~] **218.5** ASC webhook a prvé ostré hlásenie. *Čo:* agent cez `POST /v1/webhooks` (admin kľúč) zaregistruje oba typy udalostí s URL mostu, `webhookPings` overí doručenie, `GET /v1/apps/{id}/betaFeedbackScreenshotSubmissions` overí, že Apple u nás hlásenia prijíma (riziko z fóra). *Kto:* agent, potom founder 1× pošle spätnú väzbu: v TestFlight buildu urob screenshot → **Share Beta Feedback** → napíš „test 218“ → **Submit**. *Hotovo:* doručenie `SUCCEEDED` v `deliveries` a issue s analýzou a screenshotom v `trubbo-triage`. *Cena:* 0 $.
- [~] **218.6** Oprava po súhlase. *Čo:* `fix.yml` na štítok `oprav` / komentár `/oprav` (len od `michalkalis`), Claude v checkoute `quiz-agent` s tokenom `trubbo-triage-fix`: vetva, test ktorý padá pred opravou, oprava, PR s Conventional Commit názvom a odkazom na triáž (bez osobných údajov); stav PR sa vráti do issue. Produktové otázky (UX, rozsah) Claude nerieši sám, napíše ich do issue a čaká. *Kto:* agent (stavba), founder (štítok). *Hotovo:* skúšobná oprava malej chyby prejde review a CI a zlúči sa; issue sa po zlúčení zavrie. *Cena:* 0 $.
- [x] **218.7** Denný strop AI na hráča (globálny strop NIE, rozhodnutie 3). *Čo (pôvodný návrh, globálna časť vypadla):* globálny denný rozpočet AI hodnotenia odpovedí podľa skutočnej spotreby z odpovedí API (rovnaký vzor ako strop ElevenLabs); po prekročení hodnotí len rýchla cesta (presná zhoda, MCQ, fonetika) do polnoci UTC a príde 1 mail. Na hráča denný strop AI hodnotení (vzor `usage/caps.py`) a 1 mail, keď ho niekto naozaj dosiahne. *Prečo:* dnes jeden zlý deň alebo ukradnutá identita míňa zdieľaný kredit bez stropu (hlásime len zostatky). *Kto:* agent, hodnoty potvrdí founder (otázka 3). *Hotovo:* testy (nad stropom žiadne platené volanie, hráč dostane rovnaký 429 ako pri iných stropoch, mail max 1× denne), nasadené, aktuálna denná spotreba viditeľná v `ops-health`. *Cena:* 0 $ (šetrí).
- [~] **218.8** Uzavretie. Zápis do `docs/setup/incident-runbook.md` (kde sú issues, ako schváliť opravu, ako vypnúť most prepínačom `app_switches`), `/check-crashes` odkáže na triáž, záznam v `docs/issues/INDEX.md`. *Kto:* agent. *Cena:* 0 $.

Poradie: 218.1 hneď (nezávislé). 218.2 → 218.3 → 218.4 → 218.5 → 218.6. 218.7 paralelne.

## Stav (2026-11-03)

- **Beží:** most v quiz-agente (PR #678), triáž a oprava v `trubbo-triage`, strop AI na hráča (PR #676: nad stropom bez 429, voľné odpovede sa hodnotia ako nesprávne), pravidlo Sentry (PR #675, aplikované 11-03). Prvé ostré issue zo Sentry s rozborom: `trubbo-triage#11`.
- **ASC webhook** vytvorený ručne v App Store Connect (Users and Access → Integrations → Webhooks, `trubbo-triage`), lebo kľúč triáže má rolu Developer: hlásenia číta, webhooky spravovať nesmie (403). Ping overil podpis (server ho prijal). Tajný kód: `ASC_WEBHOOK_SECRET` vo Fly aj v `trubbo-triage`; pri zmene treba nový kód vložiť aj do ASC.
- **Uptime monitor Sentry** stále meria `http://quiz-agent-api.fly.dev` (koreň, 200), nie `/api/v1/health`: úpravu automaticky vytvoreného monitora Sentry API odmieta chybou 500. Skript to hlási a pokračuje.
- **Odchýlky od plánu:** názvy polí v payloade sú `id` (nie `issue_id`), regresia = `sentry_new` na zatvorenom issue. Screenshoty z appky sa neposielajú (ostávajú v Postgres za admin kľúčom). Upozornenie na expiráciu tokenov nie je postavené (tokeny platia do 2027-11-01).
- **Lokálne testy** posielali skutočné dispatche (token v `.env`), 10 falošných issues zatvorených; zapchaté v PR #702.
- **Ostáva:** founder pošle 1 spätnú väzbu z TestFlightu („test 218“), skúšobná oprava cez štítok `oprav`.

## Riziká

- Apple príjem spätnej väzby môže viaznuť (fórum) → 218.5 overí; pády aj tak chytí Sentry.
- Predplatné Max má limity používania: pri lavíne pádov (napr. zlý build) analyzuje Claude len nové problémy, bumpy idú bez AI; strop ~10 analýz za hodinu, zvyšok čaká.
- Tokeny GitHubu expirujú 2027-11-01 (upozornenie zatiaľ nie je postavené).

## Otázky pre foundera

1. **Súkromné repo `trubbo-triage`** na issues so spätnou väzbou testerov (screenshoty, texty, build), alebo ich chceš vo verejnom `quiz-agent` bez screenshotov a mien? Odporúčam súkromné.
2. **Upozornenia:** GitHub ti pošle mail pri každom novom issue. Chceš mail pri každom novom páde a hlásení (dnes ~1–2 denne), alebo ticho a mail len pri páde, ktorý zasiahne ≥ 2 hráčov alebo sa opakuje ≥ 5× za hodinu? Odporúčam to druhé, podľa pravidla „len keď to hráči cítia“.
3. **Denný strop AI:** návrh 3 $/deň pre celú službu (dnes ~5 000 hodnotení, ďaleko nad bežným dňom) a 300 AI hodnotení na hráča za deň. Po prekročení stropu by appka hodnotila len presnú a podobnú zhodu, takže voľnejšie odpovede by mohla uznať zle. Súhlasíš s hodnotami a s týmto správaním, alebo radšej nechať AI bežať a len poslať mail?
