# Runbook výpadku (#207 — pripravenosť na produkciu, úloha 207.27)

Jedna stránka na prvých 15 minút výpadku. Podrobnosti sú v odkazovaných návodoch, tu sa neopakujú.

**Kto čo robí:** agent (session na laptope alebo `mba`) diagnostikuje, prepína prepínače, robí rollback a obnovu DB sám (Fly prod operácie sú povolené natrvalo). Founder rozhoduje len o tom, čo ide navonok (text oznamu nad rámec šablóny nižšie, refundy, odpovede zákazníkom) a robí kroky, ku ktorým agent nemá prístup (App Store Connect, Apple refund, podpisy).

## 1. Ako sa o výpadku dozvieme

| Zdroj | Čo chodí | Oneskorenie |
|---|---|---|
| E-mail `[Trubbo ALERT] <kľúč>: <stav>` od `monitor@trubbo.app` | Len keď to hráči cítia teraz alebo čoskoro: quiz-agent neodpovedá (3 min), Fly worker mŕtvy 30 min, disk / pamäť / DB spojenia produkčných appiek ≥ 70 % (pamäť 90 %), p95 odozvy > 8 s 15 min v kuse pri ≥ 30 požiadavkách / 10 min, kredity providerov, zlyhaná kontrola kreditov, denný rozpočet ElevenLabs, zaplatené objednávky visia alebo sú na refund. Zálohy (WAL archív, PITR) sa len logujú, vidno ich v `GET /api/v1/admin/ops-health` | 3 až 30 min |
| E-mail `[Trubbo OK] <kľúč> recovered` | ten istý problém sa vyriešil (1 mail na problém, deploy nespamuje) | — |
| GitHub e-mail o zlyhanom behu `prod-monitor` | zdravie oboch API, visiace objednávky, heartbeat workera, aj keď **padol celý región cdg** (vtedy nemá kto poslať `[Trubbo ALERT]`) | ~30 min až 4 h |
| GitHub issue `deploy-failed` (e-mail) | `backend-deploy.yml` zastal na stagingu alebo prode | hneď |
| Sentry (org `missinghue`, projekt `carquiz`) | pády appky, chyby a varovania backendu (Sentry Logs 30 dní) | bonus, nie alarm |

Mechanika alarmov: `packages/shared/quiz_shared/ops_alerts.py`, `.github/workflows/prod-monitor.yml`. Gmail filter na `[Trubbo ALERT]` = dôležité (founder krok v #207).

## 2. Prvé kontroly (5 min)

1. Zdravie: `curl -s https://quiz-agent-api.fly.dev/api/v1/health` a `curl -s https://quiz-pack-api.fly.dev/health`.
2. Celkový stav jedným volaním (disk, pamäť, DB, odozva, worker ping): `curl -s -H "X-Admin-Key: $KEY" https://quiz-agent-api.fly.dev/api/v1/admin/ops-health`; kredity: `.../api/v1/admin/provider-balances`.
3. Stroje a logy: `fly status -a <app>`, `fly logs -a <app> --no-tail | tail -100` pre `quiz-agent-api`, `quiz-pack-api` (procesy `web`, `worker`), `quiz-pack-db`, Redis. Worker musí byť `started`.
4. Čo sa zmenilo: posledný beh `gh run list -w backend-deploy.yml -L 3`, `fly releases -a <app>`. Výpadok krátko po deployi = najprv rollback (bod 4), potom hľadať príčinu.
5. Fly samotné: https://status.flyio.net (región cdg), providery: status stránky Anthropic, OpenAI, ElevenLabs, OpenRouter.
6. Objednávky, ktoré čakajú alebo sú na refund: `curl -s -H "X-Admin-Key: $PACK_KEY" https://quiz-pack-api.fly.dev/api/v1/admin/orders/attention`.

Admin kľúče: GitHub secrets `QUIZ_AGENT_ADMIN_API_KEY` (`$KEY`) a `QUIZ_PACK_ADMIN_API_KEY` (`$PACK_KEY`), na laptope v `.env`.

## 3. Prepínače (bez reštartu, hneď)

Všetko cez `PUT /api/v1/admin/app-switches`, príkazy a hodnoty v [app-switches.md](app-switches.md):

- **Oznam** (`notice_sk` / `notice_cs` / `notice_en`): pri každom výpadku, ktorý používateľ cíti dlhšie ako ~10 min.
- **Objednávky stop** (`orders_enabled: false`): keď nebeží generovanie balíčkov, DB alebo platby. Existujúce objednávky bežia ďalej.
- **Minimálna verzia** (`min_version_app_store` / `min_version_testflight`): keď je chyba v konkrétnom builde a oprava je už v App Store / TestFlight.
- Automatické poistky, ktoré netreba prepínať: záložný hlas pri dennom strope ElevenLabs, záložný hodnotiteľ odpovedí na priamom OpenAI, prepnutie embeddingov z OpenRouter na OpenAI pri kritickom kredite (príde v maile).
- Celé AI na kanonických providerov: Fly secret `LLM_GATEWAY=direct` na oboch appkách (reštartuje stroj, preto až keď prepínače nestačia), pozri `.claude/rules/backend.md`.

## 4. Rollback backendu

Normálna cesta je nasadiť opravu cez `gh workflow run backend-deploy.yml -f apps=<app>` (testy → staging → prod). Keď treba späť hneď, predošlý obraz bez migrácie podľa `/deploy` skillu, sekcia Rollback (`.claude/skills/deploy/SKILL.md`):

1. `fly releases --image -a <app>` a vyber posledný dobrý obraz.
2. `fly deploy --image <obraz> -a <app> --skip-release-command` (migrácie sú len pridávajúce, DB sa nikdy nevracia `alembic downgrade`).
3. Smoke: `infra/deploy/smoke.sh <app> <url>`.

Ručný deploy z laptopu: najprv zámok `mkdir /tmp/trubbo-deploy-<app>.lock`, po skončení `rmdir`. Ďalšie pasce: [../runbooks/fly-deploy.md](../runbooks/fly-deploy.md).

## 5. Obnova databázy

Dáta poškodené / zmazané alebo zmizol DB stroj: [db-backup.md](db-backup.md), časť Obnova. Najprv **Objednávky stop** (bod 3) a oznam, potom kroky B.1 až B.9 (obnova do novej DB vedľa pôvodnej, prepnutie až po kontrole) a **vždy krok 10**: `python -m app.storekit.reconcile` porovná App Store nákupy s DB a dorobí objednávky zaplatené po čase zálohy; čo sa dorobiť nedá, ide na refund. Na konci prepínače späť (`reset`). Staré dáta (`quiz_pack_broken`) mazať až po reconcile.

### 5a. Výpadok celého regiónu cdg (DB aj appky preč)

Všetky prod stroje (quiz-agent, quiz-pack-api, quiz-pack-db, Redis) sú v `cdg`. Pri výpadku regiónu nemá kto poslať `[Trubbo ALERT]` a nefungujú ani prepínače (sú v DB): signál je len zlyhaný `prod-monitor` a https://status.flyio.net. Krátky výpadok (Fly ho rieši, odhad < ~1 h) sa prečká; dlhší = obnova z R2 inde.

Čo sa líši od bodu 5:

1. **Token na R2 archív je mimo cdg.** Zapisovací token je len Fly secret `S3_ARCHIVE_CONFIG` na `quiz-pack-db` (pri výpadku nečitateľný). Obnova berie čítací token z root `.env` na laptope: `PITR_R2_ACCESS_KEY_ID`, `PITR_R2_SECRET_ACCESS_KEY`, `PITR_R2_ENDPOINT` (EU endpoint) a `PITR_R2_BUCKET` (token `pitr-restore-readonly`, len čítanie `quiz-pack-db-wal`, overené 2026-10-19). Ďalší čítací token je v GitHub secrets súkromného repa (len pre workflow).
2. **Obnova v inom regióne** (`fra` / `ams`, cvičenie 2026-10-19 v `fra`): `fly apps create <app>`, token cez `fly secrets import` (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, ENDPOINT `https://bff6d086844b7b18fbb5065d179f1fcf.eu.r2.cloudflarestorage.com`, ARCHIVE `s3://quiz-pack-db-wal`, SERVER `quiz-pack-db`) **pred** vytvorením stroja (`fly secrets deploy` na appke bez deployu nefunguje), potom `fly machine run pgvector/pgvector:pg17 infinity --entrypoint sleep --region fra --vm-memory 2048 --file-local /s/pitr-restore.sh=<súkromné repo>/scripts/pitr-restore.sh` a `fly ssh console -C "bash /s/pitr-restore.sh"` (koniec archívu). Kontrola počtov a `alembic_version` (obe hlavy) ako v [db-backup.md](db-backup.md).
3. **Namerané 2026-10-19:** RPO ~1,5 min (posledná obnovená transakcia 07:34:24 UTC, obnova hotová ~07:36; zaručené ≤ 5 min cez `archive_timeout`). RTO databázy ~11 min od štartu stroja (base 10 s, 218 WAL segmentov 549 s ≈ 2,5 s/segment, rastie s časom od posledného base backupu, najhoršie ~12 min), ~15 min od `fly apps create`. 20 tabuliek (otázky, preklady, účty, objednávky, kredity, sessions, hodnotenia, nahrávky, analytika…) a obe migračné hlavy zhodné s prodom k času T. Cena < 0,01 $.
4. **Neskúšané, odhad +30–60 min:** pre ostrý beh obnovovať do stroja s volume a naším obrazom `quiz-pack-db` (heslo, `listen_addresses` na 6PN; pri `pgvector` obraze `REINDEX DATABASE` kvôli inej glibc), nastaviť `DATABASE_URL` oboch appiek na nový stroj, appky naklonovať do nového regiónu (`fly machine clone <id> --region fra`, alebo `fly deploy` s novým `primary_region`), nový prázdny Redis (objednávky z fronty dorovná sweep). Názvy appiek a `*.fly.dev` sú globálne, iOS sa nemení. Potom bod 5, krok 10 (reconcile objednávok po čase T).

## 6. Pack worker nebeží

- Fly worker padol: alarm `pack worker: down`. Najprv `fly status -a quiz-pack-api` a `fly machine start <id worker> -a quiz-pack-api`; logy ukážu dôvod (Redis, kredit Anthropic, OOM).
- Worker sa po páde reštartuje sám (Fly `restart policy = always`) a pri štarte čaká na Redis až ~10 min (207.29). Ak napriek tomu stojí, bol zastavený ručne (`fly machine stop`) alebo má problém Fly; vtedy ho spusti ručne.
- Záloha na `mba` preberá **len beta (Sandbox) objednávky** sama po 5 min bez heartbeatu, nič sa neprepína. Objednávky z App Store čakajú vo fronte na Fly worker. Postup a núdzové prepnutie: [session-worker-mba.md](session-worker-mba.md).
- Výpadok dlhší ako ~1 h: **Objednávky stop** + oznam; visiace zaplatené objednávky z `orders/attention` po oprave dobehnú samy (sweep), inak refund cez Apple.

## 7. Komunikácia s používateľmi

- **V appke:** oznam (bod 3), krátko, bez technických detailov, všetky tri jazyky naraz. Šablóna: sk „Niektoré funkcie dnes nefungujú, opravujeme to.“ · cs „Některé funkce dnes nefungují, opravujeme to.“ · en „Some features aren't working right now. We're fixing it.“ Po vyriešení oznam `reset`.
- **Zákazník s problémom objednávky:** odpoveď z `hi@trubbo.app`; refund robí Apple (zákazník cez reportaproblem.apple.com), my objednávku dorobíme alebo potvrdíme refund. Text odpovede schvaľuje founder.
- **TestFlight testeri:** pri chybe buildu poznámka v „What to Test“ ďalšieho buildu, buildy len na žiadosť foundera.
- **Web:** stránka podpory `apps/website/public/*/support.html` len pri dlhom výpadku (viac ako deň).

## 8. Po incidente

Do 24 h krátky záznam do issue (`docs/issues/`): čo sa stalo, kedy alarm prišiel vs. kedy problém začal, čo pomohlo, čo zmeniť, aby to alarm chytil skôr alebo to nenastalo. Prepínače a zámky vrátiť, oznam zrušiť.
