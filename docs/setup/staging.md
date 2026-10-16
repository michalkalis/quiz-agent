# Staging backendu (#193 — spevnenie pred betou, úloha 193.10)

Lacné predprodukčné prostredie na skúšku rizikových zmien backendu a migrácií na kópii prod dát. Len backend: iOS staging build sa nerobí (TestFlight = len prod, od 2026-07-30).

| | URL | Fly appka |
|---|---|---|
| quiz-agent | https://quiz-agent-api-staging.fly.dev/api/v1/health | `quiz-agent-api-staging` (`apps/quiz-agent/fly.staging.toml`) |
| quiz-pack-api | https://quiz-pack-api-staging.fly.dev/health | `quiz-pack-api-staging` (`apps/quiz-pack-api/fly.staging.toml`) |

Oba stroje sa uspia, keď na ne nikto nevolá, a zobudia sa prvou požiadavkou (~10 až 20 s). Worker quiz-pack-api má **0 strojov**: pohotovostný worker by bežal stále a jeho sweep by znova spustil skopírované prod objednávky na platených LLM kľúčoch.

## Izolácia od produkcie

- **Postgres:** logická DB `quiz_pack_staging` na prod klastri `quiz-pack-db`. Staging roly (`quiz_agent_api_staging`, `quiz_pack_api_staging`) nemajú žiadne práva na prod `quiz_pack` (overené 2026-10-08: SELECT na prod tabuľky odmietnutý). V staging DB vystupujú ako rola `quiz_staging`, ktorá vlastní všetky objekty.
- **Redis:** rovnaký `quiz-pack-redis`, ale DB `/1` (prod a session worker na mba používajú `/0`), takže fronty sa nikdy nemiešajú.
- **Tajomstvá:** mená ako v prode. `DATABASE_URL`, `REDIS_URL`, `STOREKIT_ENVIRONMENT`, `RC_ALLOWED_ENVIRONMENT` sú vlastné stagingu. `ORDER_QUEUE_NAME` sa zámerne nenastavuje.
- **Kľúče providerov (#207, úloha 207.17):** staging mal do 2026-10-16 rovnaké platené kľúče ako prod (zhodné digesty v `fly secrets list`). Odvtedy má `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `ELEVENLABS_API_KEY` (quiz-agent) a `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `TAVILY_API_KEY` (quiz-pack-api) nefunkčné zástupné hodnoty `*-staging-disabled-207`: staging nemôže minúť prod kredit. Appky bežia, health, migrácie a API fungujú, len volania AI zlyhajú. Vlastné kľúče s nízkym limitom pozri Founder kroky. `ADMIN_API_KEY` quiz-agent stagingu je vlastný (GitHub secret `QUIZ_AGENT_ADMIN_API_KEY` v prostredí `staging`).
- **Kontrola zdieľaných kľúčov:** `fly secrets list -a <staging appka> --json` a to isté pre prod appku; rovnaký `digest` pri tom istom mene = zdieľaná hodnota.

## Nasadenie

Bežne netreba nič: workflow **Backend Deploy** (`.github/workflows/backend-deploy.yml`) nasadí staging pred každým prod deployom a spustí smoke test. Vetvu na staging (bez produ): `gh workflow run backend-deploy.yml --ref <vetva> -f apps=both`.

Ručne, z koreňa repa, na checkoute vetvy, ktorú chceš skúsiť:

1. `fly deploy -c apps/quiz-agent/fly.staging.toml --ha=false`
2. `fly deploy -c apps/quiz-pack-api/fly.staging.toml --process-groups web --ha=false`
   Bez `--process-groups web` deploy založí 2 worker stroje. Ak sa to stane: `fly scale count worker=0 -a quiz-pack-api-staging --yes`.
3. Kontrola: obe URL vyššie vrátia 200.

`release_command` (`alembic upgrade head`) beží pred rolloutom rovnako ako v prode, takže nová migrácia sa tu vyskúša prvá. Návrat na main: rovnaké príkazy na checkoute `main`. Staging DB sa nikdy nedowngraduje; po neúspešnej migrácii ju obnov (nižšie).

Skúška generovania packov: `fly scale count worker=1 -a quiz-pack-api-staging --yes`, po skúške späť na 0. Worker potrebuje generačné tajomstvá (pozri Founder kroky).

## Obnova staging DB z produkcie

`infra/quiz-pack-db/refresh-staging.sh` zmaže a znova vytvorí `quiz_pack_staging`, nahrá doň dáta, odovzdá objekty role `quiz_staging` a vypíše počty a hlavy migrácií oproti produ. Pred začatím skontroluje miesto: ak by volume presiahol 60 %, skončí.

- `infra/quiz-pack-db/refresh-staging.sh backup` — najnovšia nočná šifrovaná záloha (alebo `backup <tag>`). Je to zároveň skúška obnovy zálohy. Potrebuje súkromný kľúč (`BACKUP_KEY`, predvolene `~/quiz-pack-db-backup-key/backup-private-key.pem`) a `gh`.
- `infra/quiz-pack-db/refresh-staging.sh prod` — čerstvý `pg_dump` produ priamo na DB stroji, bez kľúča.

Potom nasaď staging (kroky vyššie), aby `release_command` dotiahol migrácie na hlavu kódu.

## Uspanie a zrušenie

- Uspanie netreba, stroje sa uspia samé. Okamžite: `fly machines list -a <appka>`, potom `fly machine stop <id> -a <appka>`.
- Úplné zrušenie: `fly apps destroy quiz-agent-api-staging` a `fly apps destroy quiz-pack-api-staging`, potom na DB stroji (`fly ssh console -a quiz-pack-db`, `psql -p 5433 -U postgres`) `DROP DATABASE quiz_pack_staging` a `DROP ROLE` pre `quiz_agent_api_staging`, `quiz_pack_api_staging`, `quiz_staging`.

## Cena

V pokoji ~0,20 $ mesačne: 1 GB volume quiz-agent (0,15 $) a disky uspatých strojov. DB a Redis bežia na existujúcich prod strojoch, staging DB zaberie ~90 MB z 1 GB volume. Bežiaci stroj (512 MB) stojí ~0,0044 $ za hodinu, takže aj desiatky hodín skúšok mesačne zostanú pod 1 $. Worker na 1 stroji 24/7 by bol +3,2 $.

## Founder kroky

Len ak chceš na stagingu skúšať aj volania AI (hranie kvízu cez API, generovanie packov). Deploy, migrácie a smoke testy fungujú aj bez toho. Nikdy nekopíruj na staging prod kľúče.

1. **OpenRouter:** openrouter.ai → Settings → Keys → Create Key, názov `trubbo-staging`, Credit limit `2` ($). Skopíruj kľúč.
2. **OpenAI:** platform.openai.com → Settings → Projects → Create project `trubbo-staging`. V projekte Limits → mesačný budget `2` $ (či je to tvrdý strop alebo len upozornenie, neoverené; ak len upozornenie, stačí nízky limit na OpenRouteri a OpenAI nechaj neplatný). Potom v projekte API keys → Create new secret key. Skopíruj.
3. **ElevenLabs** (len quiz-agent, hlas): elevenlabs.io → Developers → API Keys → Create API Key `trubbo-staging`, zapni limit kreditov (napr. `2000`), ak ho formulár ponúka. Skopíruj.
4. **Anthropic** (len pre generovanie packov): console.anthropic.com → Settings → Workspaces → Create workspace `staging` so Spend limit `2` $ → v ňom Create Key. Skopíruj.
5. V termináli (hodnoty vlož namiesto `…`):
   ```
   fly secrets set -a quiz-agent-api-staging --stage OPENAI_API_KEY=… OPENROUTER_API_KEY=… ELEVENLABS_API_KEY=…
   fly secrets set -a quiz-pack-api-staging --stage OPENAI_API_KEY=… OPENROUTER_API_KEY=… ANTHROPIC_API_KEY=…
   ```
6. Nastavenia generovania (nie sú to kľúče, kópia z produ je v poriadku), raz z koreňa repa:
   ```
   scripts/staging-copy-secrets.sh quiz-pack-api quiz-pack-api-staging \
     LLM_ROLE_GEN LLM_ROLE_CRITIQUE LLM_ROLE_NORMALIZE VERIFY_MODEL JUDGE_MODELS \
     SCORER_MAX_CONCURRENT OVERGEN_MULTIPLIER STAGE_TIMEOUT_SECONDS
   ```
7. Prejaví sa pri ďalšom deployi stagingu (`gh workflow run backend-deploy.yml --ref main -f apps=both` alebo najbližší merge).
