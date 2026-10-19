# Záloha a obnova quiz-pack-db (#193 — spevnenie pred betou, úloha 193.4)

`quiz-pack-db` (Fly Postgres, 1 stroj, 1 GB volume) drží celý prod stav: otázky, objednávky, účty a prihlásenie, analytiku, hodnotenia. Fly robí denné snapshoty volume (5 dní, rovnaký región). Tento dokument popisuje druhú, nezávislú zálohu mimo Fly.

## Ako to beží

- Každú noc o 02:17 UTC beží workflow `backup.yml` v **súkromnom** repe [michalkalis/quiz-agent-db-backups](https://github.com/michalkalis/quiz-agent-db-backups). Súkromné preto, lebo artefakty a releasy verejného monorepa si môže stiahnuť ktokoľvek s GitHub účtom.
- Workflow spustí `infra/quiz-pack-db/backup.sh` z `main` tohto monorepa. Skript cez `fly ssh` spustí na DB stroji `pg_dump` (custom formát) a výstup hneď tam zašifruje `openssl cms` (AES-256) na verejný certifikát. Z Fly odchádza len šifrovaný text, nešifrovaná kópia nikde nevzniká.
- Výsledok sa uloží ako release `db-<dátum>` (súbor `quiz-pack-db-<dátum>.dump.cms`, ~35 MB v októbri 2026). Drží sa najnovších 30, staré sa mažú až po úspešnom nahratí novej.
- Zlyhaný beh = e-mail od GitHubu vlastníkovi repa. Beh zlyhá aj vtedy, keď je `/data` na DB stroji zaplnený na 80 % a viac (záloha sa aj tak nahrá).

Tajomstvá v súkromnom repe:

| Názov | Druh | Čo to je |
|---|---|---|
| `FLY_BACKUP_SSH_TOKEN` | secret | `fly tokens create ssh -a quiz-pack-db`, platí do 2026-10-08 + 1 rok (**2027-10-08**). Potom vytvoriť nový a prepísať: `fly tokens create ssh -a quiz-pack-db -x 8760h \| tr -d '\n' \| gh secret set FLY_BACKUP_SSH_TOKEN -R michalkalis/quiz-agent-db-backups` |
| `BACKUP_CERT_B64` | variable | Verejný certifikát (base64 PEM), `CN=quiz-pack-db-backup`. Nie je tajný. |

**Súkromný kľúč** (`backup-private-key.pem`) už nie je ako súbor na disku. Kópie:
- macOS login Keychain, položka `quiz-pack-db backup key (base64 PEM)`. Obnova do súboru: `security find-generic-password -s 'quiz-pack-db backup key (base64 PEM)' -w | base64 -d > key.pem && chmod 600 key.pem` (po obnove `key.pem` zmazať).
- GitHub secret `BACKUP_DECRYPT_KEY_PEM` (a `BACKUP_CERT_PEM`) v súkromnom repe, len na zápis. Použiteľný iba cez workflow v tom repe (verify workflow nižšie, alebo obnova spustená v Actions).

Bez kľúča sa žiadna záloha nedá obnoviť; kto má kľúč a prístup k repu, prečíta celú databázu.

**Týždenná kontrola** (workflow `quiz-pack-db backup verify`, pondelky 05:43 UTC + ručne): stiahne najnovšiu zálohu, dešifruje ju secretom `BACKUP_DECRYPT_KEY_PEM`, spustí `pg_restore --list` (postgres 17) a overí, že tabuľka `questions` je v dumpe. Vypisuje len počty. Zlyhanie = e-mail od GitHubu; znamená, že záloha alebo secret kópia kľúča je pokazená.

Sessions, hodnotenia, cache prekladov a stav upozornení quiz-agentu sú od #207.20 v Postgrese, takže ich záloha je súčasťou tohto dumpu. Staré SQLite súbory z volume `quiz-agent-api` boli 2026-10-16 jednorazovo skopírované do Postgresu; volume bol 2026-10-19 zmazaný po kontrole, že v Postgrese aj R2 je všetko (krok 6 návrhu odolnosti).

## Obnova k ľubovoľnému okamihu (PITR, #207.20, od 2026-10-16)

Druhá vrstva vedľa nočného dumpu: postgres-flex (barman-cloud 3.10 v našom obraze) posiela každý WAL segment do súkromného R2 bucketu `quiz-pack-db-wal` (firemný Cloudflare účet hello@missinghue.com, jurisdikcia EÚ). Segment sa uzavrie najneskôr každých 300 s, takže strata pri havárii je ≤ ~5 min (RPO). Plná záloha (base backup) raz za 24 h, drží sa 7 dní: obnoviť sa dá ktorákoľvek sekunda za posledných 7 dní.

- Zapnuté Fly secretom `S3_ARCHIVE_CONFIG` na `quiz-pack-db` (`https://<key>:<secret>@<účet>.eu.r2.cloudflarestorage.com/quiz-pack-db-wal/quiz-pack-db`; posledná časť = meno barman servera). Token je zapisovací, len na tento bucket.
- `archive_timeout` 300 s: `flexctl backup config update --archive-timeout 300s` (platí po reštarte) a zároveň `ALTER SYSTEM SET archive_timeout = 300` (hneď, prežije reštart). Kontrola: `SHOW archive_timeout`, `flexctl backup list`.
- Stav: `fly ssh console -a quiz-pack-db -C "flexctl backup list"`, v DB `select * from pg_stat_archiver`.
- **Stráž** (quiz-agent ops watch, `app/monitoring/wal_watch.py`): e-mail pri zlyhaní archivácie alebo keď 15 min nič neodišlo, pri `pg_wal` > 500 MB; pri > 1,5 GB sama vypne archiváciu (`archive_command = '/bin/true'`), aby sa disk nezaplnil, a pošle „PITR gap“. **Návrat po oprave R2/tokenu:** `ALTER SYSTEM RESET archive_command` + `SELECT pg_reload_conf()` (bez reštartu), potom `flexctl backup create`. Vyskúšané 2026-10-16 na skúšobnej kópii aj bez reštartu.
- **Týždenná skúška obnovy:** workflow `quiz-pack-db PITR restore verify` v súkromnom repe (pondelky 06:17 UTC + ručne). Obnoví najnovšiu base + celý WAL bežným barman-cloud (bez Fly) do Postgres 17 + pgvector a overí, že posledný heartbeat workera je ≤ 10 min pred štartom a `questions` > 1000. Token len na čítanie (`PITR_R2_RO_*` secrets, `PITR_*` variables). Ručný beh s `server` = prázdny adresár musí zlyhať (červený test, overené).

**Obnova k času T** (skript `scripts/pitr-restore.sh` v súkromnom repe; bez Fly, rovnaká cesta ako odchod do iného regiónu/Hetzneru):

1. Potrebuješ token na čítanie (R2 → API tokens, alebo secrets zo súkromného repa) a Docker.
2. `docker run -d --name pitr --entrypoint sleep -e AWS_ACCESS_KEY_ID=… -e AWS_SECRET_ACCESS_KEY=… -e ENDPOINT=https://bff6d086844b7b18fbb5065d179f1fcf.eu.r2.cloudflarestorage.com -e ARCHIVE=s3://quiz-pack-db-wal -e SERVER=quiz-pack-db -v <repo>/scripts:/s:ro pgvector/pgvector:pg17 infinity`
3. `docker exec pitr bash /s/pitr-restore.sh "2026-10-16 13:34:33+00"` (bez času = koniec archívu). Base (223 MB) ~10 s, potom prehrávanie WAL ~2,5 s na segment: tesne po base backupe ~1 min, deň po ňom (~220 segmentov) ~9 min, najhoršie (24 h WAL) ~12 min.
4. Kontrola: `docker exec -u postgres pitr psql -p 5499 -d quiz_pack -c "…"`. Potom buď vybrané riadky ručne späť do produ, alebo celá DB podľa postupu B nižšie (dump z kontajnera namiesto zálohy z GitHubu).

Overené 2026-10-16 naostro na produ: obnova k 13:34:33 UTC vrátila presne stav z toho okamihu (heartbeat 13:34:14, 3439 otázok, 3 sessions, 319 analytických udalostí, ako v prode v tej sekunde); posledná transakcia 13:34:29, nasledujúca (13:34:34) už nie. Skúška na kópii: zmazanie 1000 riadkov po čase T bolo v obnove vrátené.

Pozn.: obraz `pgvector/pgvector:pg17` má staršiu glibc (2.36) než DB stroj (2.39); Postgres to len ohlási ako varovanie o verzii collation. Pri obnove, ktorá má nahradiť prod, sprav na obnovenej DB `REINDEX DATABASE` alebo obnovuj do nášho obrazu `quiz-pack-db`.

## Obnova

Potrebuješ: `gh` prihlásený na účet `michalkalis`, `openssl` 3 (`brew install openssl@3`), Docker, `fly` prihlásený na org, súkromný kľúč uložený do súboru `key.pem` (`chmod 600 key.pem`, po obnove zmazať).

### A. Skúška obnovy naostro bez zásahu do produkcie (overené 2026-10-08)

Databáza beží v RAM kontajnera (tmpfs), po `docker stop` po nej nič nezostane.

1. `gh release list -R michalkalis/quiz-agent-db-backups --limit 5` a vyber tag.
2. `gh release download <tag> -R michalkalis/quiz-agent-db-backups`
3. `docker run -d --rm --name qp-restore-test -e POSTGRES_PASSWORD=restoretest --tmpfs /var/lib/postgresql/data:rw,size=2g pgvector/pgvector:pg17`
4. `docker exec qp-restore-test createdb -U postgres quiz_pack`
5. `openssl cms -decrypt -binary -inform DER -inkey key.pem -in quiz-pack-db-<dátum>.dump.cms | docker exec -i qp-restore-test pg_restore -U postgres -d quiz_pack --no-owner --no-privileges --exit-on-error`
6. Kontrola: `docker exec qp-restore-test psql -U postgres -d quiz_pack -Atc "select count(*) from questions" -c "select version_num from alembic_version"` — počty porovnaj s produkciou.
7. `docker stop qp-restore-test`, zmaž `key.pem` a stiahnutý súbor.

Skúška obnovy do staging DB (stagingu sa potom dá aj nasadiť): `infra/quiz-pack-db/refresh-staging.sh backup`, pozri `docs/setup/staging.md`.

### B. Obnova do produkcie (DB stroj žije, dáta sú poškodené alebo zmazané)

Obnovuje sa do novej databázy vedľa pôvodnej, prepne sa až po kontrole, takže pôvodné dáta ostanú pre prípad omylu. Zápisy od času zálohy sú potom len v `quiz_pack_broken`.

Zapisovateľov nezastavuj cez `fly machine stop`: obe appky majú `auto_start_machines`, takže ich prvá požiadavka z iOS znova zobudí. A keďže sa pripájajú ako superuser, `REVOKE CONNECT` ich nezastaví. Spoľahlivé je zamknúť samotnú databázu (krok 4); appky medzitým vracajú chyby, to je pri obnove v poriadku.

1. Zastav oba pack workery, nech počas obnovy nič negenerujú: Fly worker `fly machine stop <id stroja worker z fly status> -a quiz-pack-api` (worker nemá službu, sám sa nezobudí) a záložný worker na mba `apps/quiz-pack-api/scripts/session_worker_local.sh uninstall-launchd`.
2. V druhom termináli: `fly proxy 15432:5432 -a quiz-pack-db`
3. Heslo a skratka:
   `export PGPASSWORD=$(fly ssh console -a quiz-pack-db -C 'printenv OPERATOR_PASSWORD' | tail -1 | tr -d '\r')`
   `PSQL="docker run --rm -i -e PGPASSWORD postgres:17 psql -h host.docker.internal -p 15432 -U postgres -d postgres"`
4. Zamkni starú databázu a odpoj všetkých (aj spojenia držané proxy na porte 5432):
   `$PSQL -c "ALTER DATABASE quiz_pack WITH ALLOW_CONNECTIONS false" -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'quiz_pack'"`
5. `$PSQL -c 'CREATE DATABASE quiz_pack_restore'`
6. `openssl cms -decrypt -binary -inform DER -inkey key.pem -in <súbor>.dump.cms | docker run --rm -i -e PGPASSWORD postgres:17 pg_restore -h host.docker.internal -p 15432 -U postgres -d quiz_pack_restore --no-owner --no-privileges --exit-on-error`
7. Over počty ako v A.6 (`docker run --rm -e PGPASSWORD postgres:17 psql -h host.docker.internal -p 15432 -U postgres -d quiz_pack_restore -Atc "select count(*) from questions"`).
8. Prepni: `$PSQL -c 'ALTER DATABASE quiz_pack RENAME TO quiz_pack_broken' -c 'ALTER DATABASE quiz_pack_restore RENAME TO quiz_pack'`
9. `fly apps restart quiz-agent-api` (drží mŕtve spojenia), `quiz-pack-api` sa zobudí sám pri prvej požiadavke. Skontroluj `https://quiz-agent-api.fly.dev/api/v1/health` a `https://quiz-pack-api.fly.dev/health`, potom `fly machine start <id worker> -a quiz-pack-api` a na mba `session_worker_local.sh install-launchd`. Do `quiz_pack_broken` sa dá nahliadnuť po `ALTER DATABASE quiz_pack_broken WITH ALLOW_CONNECTIONS true`; zmaž ju, až keď je všetko v poriadku (najprv krok 10).
10. Zaplatené objednávky po čase zálohy (#207 — pripravenosť na produkciu, úloha 207.6 — kontrola objednávok po obnove): `fly ssh console -a quiz-pack-api -C "python -m app.storekit.reconcile --since <čas zálohy, napr. 2026-10-16T02:17:00Z> --source-db <DATABASE_URL s menom quiz_pack_broken>"`. Opýta sa App Store Server API na nákupy balíčkov všetkých zákazníkov, ktorých DB pozná, a vypíše tie bez objednávky. `would_recreate` = riadok je v `quiz_pack_broken`, rovnaký príkaz s `--apply` objednávku obnoví a zaradí na generovanie (opakované spustenie nič nezdvojí). `no_source_row` = prompt nepozná nikto (appka si ho po prijatí objednávky nedrží): zákazník dostane refund cez Apple alebo ho požiadaj o novú objednávku. Ďalší známy nákup (napr. z e-mailu zákazníka) pridáš cez `--transaction-id`. Potrebuje Fly secrets `APP_STORE_SERVER_KEY_ID`, `APP_STORE_SERVER_ISSUER_ID`, `APP_STORE_SERVER_PRIVATE_KEY` (In-App Purchase kľúč z App Store Connect, obsah `.p8` ako PEM alebo base64).

Ak zmizol celý DB stroj alebo volume: do 5 dní najprv skús Fly snapshot (`fly volumes snapshots list vol_vxm60y5nq10xpmw4 -a quiz-pack-db`, potom `fly volumes create pg_data --snapshot-id <id> -a quiz-pack-db`). Inak vytvor nový stroj z vlastného obrazu (`infra/quiz-pack-db/README.md`) a pokračuj krokmi 2, 3, 5 až 7, potom len `$PSQL -c 'ALTER DATABASE quiz_pack_restore RENAME TO quiz_pack'` a krok 9.

## Miesto na disku

Volume nemá auto-extend: Fly Postgres stroj ho dostane len cez úpravu konfigurácie stroja, ktorá stroj reštartuje. Namiesto toho nočná záloha hlási zaplnenie nad 80 %. Zväčšenie za behu, bez reštartu: `fly volumes extend vol_vxm60y5nq10xpmw4 -a quiz-pack-db -s 2` (každý GB navyše ~0,15 $ mesačne).
