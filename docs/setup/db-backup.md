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

**Súkromný kľúč** (`backup-private-key.pem`) je len offline u foundera (správca hesiel). Bez neho sa žiadna záloha nedá obnoviť; kto má kľúč a prístup k repu, prečíta celú databázu.

SQLite súbory na volume `quiz-agent-api` (`/data/ratings.db`, `/data/translations.db`) sa nezálohujú: `ratings.db` obsahuje len rozohrané hlasové sessions s krátkou životnosťou (hodnotenia už bývajú v Postgrese) a `translations.db` je cache preložených textov, ktorú prekladač znova doplní. Volume má aj tak denné Fly snapshoty.

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

### B. Obnova do produkcie (DB stroj žije, dáta sú poškodené alebo zmazané)

Obnovuje sa do novej databázy vedľa pôvodnej, prepne sa až po kontrole, takže pôvodné dáta ostanú pre prípad omylu. Zápisy od času zálohy sú potom len v `quiz_pack_broken`.

Zapisovateľov nezastavuj cez `fly machine stop`: obe appky majú `auto_start_machines`, takže ich prvá požiadavka z iOS znova zobudí. A keďže sa pripájajú ako superuser, `REVOKE CONNECT` ich nezastaví. Spoľahlivé je zamknúť samotnú databázu (krok 4); appky medzitým vracajú chyby, to je pri obnove v poriadku.

1. Na mba zastav session worker: `apps/quiz-pack-api/scripts/session_worker_local.sh stop`.
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
9. `fly apps restart quiz-agent-api` (drží mŕtve spojenia), `quiz-pack-api` sa zobudí sám pri prvej požiadavke. Skontroluj `https://quiz-agent-api.fly.dev/api/v1/health` a `https://quiz-pack-api.fly.dev/health`, potom znova spusti worker na mba. Do `quiz_pack_broken` sa dá nahliadnuť po `ALTER DATABASE quiz_pack_broken WITH ALLOW_CONNECTIONS true`; zmaž ju, až keď je všetko v poriadku.

Ak zmizol celý DB stroj alebo volume: do 5 dní najprv skús Fly snapshot (`fly volumes snapshots list vol_vxm60y5nq10xpmw4 -a quiz-pack-db`, potom `fly volumes create pg_data --snapshot-id <id> -a quiz-pack-db`). Inak vytvor nový stroj z vlastného obrazu (`infra/quiz-pack-db/README.md`) a pokračuj krokmi 2, 3, 5 až 7, potom len `$PSQL -c 'ALTER DATABASE quiz_pack_restore RENAME TO quiz_pack'` a krok 9.

## Miesto na disku

Volume nemá auto-extend: Fly Postgres stroj ho dostane len cez úpravu konfigurácie stroja, ktorá stroj reštartuje. Namiesto toho nočná záloha hlási zaplnenie nad 80 %. Zväčšenie za behu, bez reštartu: `fly volumes extend vol_vxm60y5nq10xpmw4 -a quiz-pack-db -s 2` (každý GB navyše ~0,15 $ mesačne).
