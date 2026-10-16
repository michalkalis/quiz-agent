# Resilience design: no volume on quiz-agent, Postgres PITR, Redis, region stance (#207.19)

**Date:** 2026-10-16 · **Issue:** [#207 — production readiness](../issues/issue-207-production-readiness.md), task 207.19 (design) → 207.20 (implementation).
**Inputs:** `origin/main` 3402126c, read-only look at prod (`fly ssh`, `fly status`) on 2026-10-16, Fly / Cloudflare / Postgres / barman docs (cited inline, list at the end).
**Standing constraints:** never Fly Managed Postgres; Hetzner is the preferred future host (portable design); minimal moving parts; LLM off the hot path.

## TL;DR

1. **Postgres PITR with what the image already ships.** Our `quiz-pack-db` image (`FROM flyio/postgres-flex:17.2`) already contains barman-cloud 3.10 and a `barman_cron`; postgres-flex turns on continuous WAL archiving + daily base backups to any S3 endpoint when the secret `S3_ARCHIVE_CONFIG` is set. Point it at a private **Cloudflare R2** bucket. RPO 24 h → **≤ ~5 min** (`archive_timeout` 300 s, chosen so a stuck archiver cannot fill the disk within hours; §3.2), any second in the last 7 days restorable, archive lives outside Fly. **No replica** at our scale.
2. **quiz-agent without a volume.** Everything on `/data` moves to services we already run: quiz sessions, ratings, translation cache, alert state → **Postgres**; TTS audio → **R2**. The two machines coordinate only through Postgres rows (version check on sessions, short lease rows for leader and TTS single-flight), never long-held locks. Then **2 always-on machines + rolling deploy** → no ~18 s outage per deploy/secret change, and one dead host no longer takes the API down.
3. **Redis stays as is** (1 machine, AOF). Nothing durable lives only in Redis; orders are in Postgres and the stuck-order sweep re-drives them. Add a loss drill, no infra change.
4. **Region outage: accept, but make it recoverable.** No standby region. With the archive in R2, a cdg outage becomes "restore from R2 with stock barman-cloud into any Postgres host" (another Fly region or Hetzner), RPO ≤ ~5 min, RTO ~1–2 h; the weekly automated restore already exercises that exit path.

**Cost delta:** about **+$3.2/month** (second 512 MB machine +$3.69, 3 GB volume −$0.45; R2 stays inside its free tier). The only founder decision is that $3.69 machine (cheaper alternative in §2.4).

| | Before | After |
|---|---|---|
| Postgres RPO | up to 24 h (nightly `pg_dump`, daily Fly snapshot) | ≤ ~5 min (WAL every 300 s); nightly dump kept as 2nd copy |
| Postgres RTO, machine/volume lost | ~30–60 min manual (snapshot or dump), loses the day | ~30–60 min manual (R2 restore, measured in drill), loses ≤ 5 min |
| Postgres, bad delete / bad migration | back to last night | back to any second in 7 days |
| quiz-agent deploy / secret change | ~18 s outage each | 0 (target, verified by probe loop) |
| quiz-agent host failure | down until host returns (volume pinned to host) | other machine keeps serving |
| Redis loss | queue rebuilt by sweep in ≤ 3–15 min | same (drilled) |
| cdg region outage | RPO 24 h, RTO unknown | RPO ≤ ~5 min, RTO ~1–2 h (rehearsed) |

## 1. Today (verified 2026-10-16)

- **quiz-agent-api:** 1 × shared-cpu-1x 512 MB, cdg, volume `quiz_agent_data` 3 GB on `/data`. Actual content: `tts_cache` **36 MB** (cap `TTS_CACHE_MAX_MB` 1.5 GB), `ratings.db` 644 KB (`quiz_sessions` 70 rows, `question_ratings` 0, `model_scores` 0), `translations.db` 112 KB, `ops_alerts.json` (alert dedupe, configured but not yet written). A volume is attached to one machine on one host, so the app cannot run 2 machines sharing it, and canary/bluegreen deploys are not available for machines with volumes ([Fly config reference](https://fly.io/docs/reference/configuration/#picking-a-deployment-strategy)). With one machine every deploy is stop → start (~18 s).
- **In-process state that breaks with 2 machines** (found in code, not only on disk):
  - `SessionManager` keeps sessions in a dict (write-through to SQLite, reloaded only at boot) and serializes duplicate submits with a per-session `asyncio.Lock` (`app/session/manager.py`). A request landing on the other machine would not find the session.
  - Background monitors (`run_balance_check`, `run_daily_stock_check`, `run_ops_watch`, `run_pack_watch` in `app/main.py`) would run on both machines → double e-mails; `PackWatch.last_ping` is in memory, so the worker's minute ping reaches only one machine and the other would alarm "worker dead".
  - TTS single-flight (`TTSService._in_flight`) is per process; prefetch + client fetch of the same question landing on different machines would pay ElevenLabs twice (~185 credits per first read, Starter plan cannot top up).
  - `slowapi` limits are in memory → per-IP limits become up to 2× (accepted: the paid caps from 207.13 are in Postgres).
- **quiz-pack-db:** unmanaged Fly Postgres (postgres-flex 17.2 + pgvector), 1 machine, volume now 3 GB, data dir **286 MB**, nightly encrypted `pg_dump` (~35 MB) to a private GitHub repo with a weekly verify ([db-backup.md](../setup/db-backup.md)), Fly daily snapshots (5 days, same region). `flexctl backup config show` → "backups are not enabled". Staging uses the same cluster (separate roles).
- **quiz-pack-redis:** 1 × 256 MB, AOF on a 1 GB volume, `noeviction`, prod DB 0 / staging DB 1 ([README](../../infra/quiz-pack-redis/README.md)).
- **iOS** builds hard-code `quiz-agent-api.fly.dev` (`Prod.xcconfig`).

## 2. quiz-agent without a volume (a)

### 2.1 What moves where

| Today on `/data` or in memory | Goes to | Why there |
|---|---|---|
| `quiz_sessions` (SQLite) + in-memory dict | Postgres table with a `version` column, the source of truth; in-memory copy dropped | Small JSON rows, same region; quiz-agent already reads questions from this Postgres on the hot path, so no new failure dependency |
| `question_ratings`, `model_scores` (SQLite, empty) | Postgres tables (same alembic migration) | No SQLite left; nothing to copy |
| `translations.db` (SQLite cache) | Postgres table | Cache of paid Claude translations; must survive and be shared |
| `ops_alerts.json` (dedupe) | Postgres table | Both machines must agree what was already mailed |
| `PackWatch.last_ping` (memory) | Postgres row (upsert on ping) | Ping may land on either machine |
| `tts_cache` files (36 MB) | Private R2 bucket, key = today's cache key; small local LRU on the ephemeral rootfs as L1 | Audio bytes are blobs; R2 is already used (`r2_uploader.py`, `sample_storage.py`), no egress fee ([R2 pricing](https://developers.cloudflare.com/r2/pricing/)) |

All Postgres changes are additive alembic migrations (the existing rule; the boot check already accepts a DB that is ahead, `startup_checks.py`), so old and new machines can run side by side during a rolling deploy.

### 2.2 Cross-machine coordination: Postgres rows, no long-held locks

Rule: no lock or transaction is held across a paid call (STT, LLM, TTS) or an idle period. Prod reaches Postgres through postgres-flex's HAProxy, which cuts idle connections after 30 min ([haproxy.cfg](https://github.com/fly-apps/postgres-flex/blob/master/config/haproxy.cfg)), so a session-level advisory lock on a long-lived connection can vanish silently, or linger after a host dies.

- **Every session write is a conditional update** (optimistic concurrency): `UPDATE quiz_sessions SET data_json=…, version=version+1 WHERE session_id=… AND version=:read_version`. Today several routes write the whole session outside the submit lock (`tts.py` question prefetch after an awaited translation, `start_quiz`, `sessions.py`, `daily_challenge.py`), a lost-update race already inside one process that two machines would widen. On a miss the writer re-reads and re-applies its own change (a small `mutate(session)` callback, at most 3 tries). SQLAlchemy has this built in ([version counter](https://docs.sqlalchemy.org/en/20/orm/versioning.html)).
- **Duplicate submits:** the losing duplicate gets a version miss, re-reads, sees the question already answered and returns the stored result: the same contract as today's per-session lock. The in-process `asyncio.Lock` stays as the cheap same-machine fast path.
- **TTS single-flight:** on an L1+R2 miss, `INSERT INTO tts_inflight(key, holder, expires_at = now()+30 s) ON CONFLICT DO NOTHING` (a row past `expires_at` can be taken over). The winner synthesizes and writes R2; the other machine polls R2 for up to ~10 s, then synthesizes itself (bounded worst case = today's duplicate). Protects scarce ElevenLabs credits.
- **Monitors (leader lease):** each tick, `UPDATE monitor_leader SET holder=:me, expires_at=now()+90 s WHERE expires_at < now() OR holder=:me`; run the background monitors only while it returns a row. A dead leader is replaced within ~90 s; nothing depends on a connection staying open. Alert dedupe and the worker ping are rows, read by whichever machine leads.

*Rejected:* session-level `pg_advisory_lock` (breaks behind the HAProxy idle timeout and holds a pooled connection through paid calls; the pool is 5); sticky routing with Fly's `fly-replay` header (Fly-only, breaks the Hetzner path, and still loses state when that machine is replaced); Redis for sessions (adds quiz-agent's first dependency on Redis — a second store on the hot path — while Postgres is already there).

### 2.3 Deploy shape

- `fly.toml`: drop `[[mounts]]` and the `/data` env paths, `[deploy] strategy = "rolling"`, `max_unavailable = 1`, 2 machines, `min_machines_running = 2`, `kill_timeout` ~30 s so an in-flight STT/evaluation request finishes. Rolling is Fly's default and replaces machines one at a time behind the health check ([deploy docs](https://fly.io/docs/launch/deploy/)).
- `release_command` migrations stay; migrations must stay expand-only while two versions overlap (already the policy).
- Same image runs on Hetzner later behind any load balancer: state is in Postgres + S3-compatible storage.

### 2.4 Alternative considered: 1 machine + bluegreen

Without a volume Fly can do **bluegreen** with one machine (new machine boots, passes health, traffic flips, old one goes) at **$0** extra. It removes the deploy outage but not the single-host risk, and it still needs all of §2.1–2.2 for the overlap seconds. Recommended: 2 machines (+$3.69/mo); bluegreen-1 is the fallback if the founder declines the spend.

## 3. Postgres point-in-time recovery (b)

### 3.1 Options

| Option | RPO | RTO (machine/volume lost) | Bad delete | Region loss | Cost/mo | Moving parts |
|---|---|---|---|---|---|---|
| **A. Today:** nightly `pg_dump` + Fly snapshots | ≤ 24 h | ~30–60 min manual | last night | dump survives (GitHub) | $0 | as today |
| **B. postgres-flex built-in barman-cloud → R2** (recommended) | ≤ ~5 min (`archive_timeout` 300 s) | ~30–60 min manual, restore of ~290 MB | any second, 7 days | archive survives (Cloudflare) | ~$0 (inside R2 free 10 GB) | 1 secret + 1 bucket |
| C. Own wal-g / pgBackRest in the image | ≤ ~5 min | same as B | same | same | ~$0 | new tool + config we maintain |
| D. Streaming replica (repmgr) | ~0 for machine loss | seconds–minutes | **no** (a delete replicates) | no, if same region | +$6.70 machine + volume per node; failover needs ≥ 3 members | 1–2 more PG machines |
| E. Fly Managed Postgres | — | — | — | — | $38+ | **excluded** (standing decision) |

**Why B.** postgres-flex merged native WAL archiving in [PR #231](https://github.com/fly-apps/postgres-flex/pull/231): set `S3_ARCHIVE_CONFIG=https://<key>:<secret>@<endpoint>/<bucket>/<dir>` and the image runs `barman-cloud-wal-archive` as `archive_command`, takes base backups (defaults: full backup every 24 h, recovery window 7 d, minimum redundancy 3, `archive_timeout` 60 s), and supports restore into a new app via `S3_ARCHIVE_REMOTE_RESTORE_CONFIG` with `targetTime` ([barman.go](https://github.com/fly-apps/postgres-flex/blob/master/internal/flypg/barman.go)). Confirmed on our machine: `barman-cloud-backup 3.10.0`, `barman_cron`, `flexctl backup` present. It passes `--endpoint-url`, so R2 works as a plain S3 endpoint. **Build vs adopt:** adopt — it is already installed; C adds a tool for no gain. barman-cloud is upstream EDB tooling, so the same archive restores on Hetzner with stock `barman-cloud-restore` / `barman-cloud-wal-restore` ([barman docs](https://docs.pgbarman.org/release/3.10.0/user_guide/barman_cloud.html)).

**Why not D now.** A replica protects against hardware loss only, not against the mistakes that are our likelier failure (bad migration, buggy delete). postgres-flex wants ≥ 3 members in the primary region for automatic failover ([Fly HA guide](https://fly.io/docs/postgres/advanced-guides/high-availability-and-global-replication/)), i.e. +2 machines (~$14/mo with volumes) and repmgr split-brain care. Revisit when paid usage makes a 30–60 min RTO unacceptable.

### 3.2 Risks and how the design handles them

- **Fly no longer supports unmanaged Postgres** ([Fly backup doc banner](https://fly.io/docs/postgres/managing/backup-and-restore/)); the image repo is still maintained (release v0.2.1, 2026-08). The R2 archive is our exit: it is plain barman-cloud, restorable anywhere.
- **R2 + AWS SDK checksum breakage** (boto3 ≥ 1.36 sends default CRC checksums that some S3-compatible stores reject). Our image has **boto3 1.34.46**, before that change. Verify step 1 proves it end to end; pin the image digest so it does not drift.
- **Archive failures fill the disk (the main new risk).** A failing `archive_command` makes Postgres keep every WAL segment in `pg_wal`, and each forced switch is a full 16 MB segment ([archive_timeout](https://www.postgresql.org/docs/17/runtime-config-wal.html#GUC-ARCHIVE-TIMEOUT)). At the image default of 60 s a stuck archiver (R2 outage, revoked token) eats ~1 GB/h and fills the 3 GB volume in ~2–3 h, which stops Postgres and with it all gameplay. Three layers:
  1. `archive_timeout` **300 s** (RPO ≤ 5 min) → ~190 MB/h idle growth, a fuse of ~12 h instead of ~2 h, and 5× fewer objects in R2.
  2. Ops watch alert when `pg_stat_archiver.last_failed_time` > `last_archived_time`, the last archive is > 15 min old, or `pg_wal` > 500 MB.
  3. **Self-heal** in ops watch at `pg_wal` > 1.5 GB: `ALTER SYSTEM SET archive_command = '/bin/true'` + `pg_reload_conf()` (no restart; `postgresql.auto.conf` is read after the image's config, [ALTER SYSTEM](https://www.postgresql.org/docs/17/sql-altersystem.html)), so Postgres recycles WAL; mail "PITR gap since T". After the repair: `ALTER SYSTEM RESET archive_command`, reload, fresh base backup. Availability beats PITR; the nightly dump still covers the gap. Rehearsed in step 1 on the throwaway app.
- **Archive size.** Our minute-level writes (worker heartbeat, ops watch) mean a switch every 300 s, ≤ 288 gzipped segments/day; measured in step 1. Worst realistic case is still < $1/mo in R2. `archive_timeout` can go down to 60 s later, once the self-heal has proven itself.
- **Encryption.** R2 encrypts at rest; the bucket is private, in the EU jurisdiction, with a token scoped to this bucket only. barman-cloud has no client-side encryption (unlike our dump). On Fly the write token adds no new reader (whoever reads Fly secrets reads the DB anyway). The weekly restore workflow (step 2) is a new reader: it gets a **separate read-only** R2 token in the private backups repo, the same trust level as the `BACKUP_DECRYPT_KEY_PEM` already there. **No R2 bucket lock:** [bucket locks](https://developers.cloudflare.com/r2/buckets/bucket-locks/) refuse overwrites and deletes, so a retried WAL upload or barman's own retention delete would fail and trip the archiver (risk above). Protection against a deleted archive is the independent nightly dump on GitHub.
- **Enabling it restarts Postgres** (seconds; both apps see DB errors briefly). Do it in a quiet hour.
- Keep the nightly `pg_dump` to GitHub: a second tool, second provider, logical format.

## 4. Redis durability (c)

What Redis holds and what losing it costs (code paths in `apps/quiz-pack-api`):

| Data | If Redis dies or is wiped | Recovery |
|---|---|---|
| ARQ queue + job keys (`enqueue_job` = sorted set + payload key, [arq](https://arq-docs.helpmanual.io/)) | queued/running jobs vanish | orders + jobs are rows in Postgres; `app/worker/sweep.py` re-enqueues `pending` after 3 min and `in_progress` after 15 min; duplicate-attempt guard (PR #275) blocks double generation |
| SSE progress pub/sub | open progress streams stop | client reconnects; `sse/bridge.py` replays `step_log` from Postgres |
| JWS verify cache (60 s) | one extra signature check | none needed |

AOF `everysec` loses ≤ 1 s of writes on a crash ([Redis persistence](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)), and even a full wipe loses no order. **Decision: no change** (no replica, no Upstash). Only add the drill in step 7 so the claim is tested, not assumed. Note for later: staging still shares this Redis (DB 1).

## 5. Region outage (d)

- **Stance:** at beta scale a cdg outage is rare and survivable; a warm standby region (PG replica + app machines elsewhere) roughly doubles infra and adds cross-region failover logic. Not worth it now.
- **What makes it recoverable:** after this plan, durable state is Postgres (WAL archive in R2, dump in GitHub) and TTS audio (R2), both outside Fly. Redis can start empty.
- **Runbook (goes into 207.27 incident runbook):** restore the R2 archive with stock `barman-cloud-restore` + `barman-cloud-wal-restore` into a Postgres 17 + pgvector host in another EU region (a Fly machine with a volume running our image, or a Hetzner VM; not dependent on `fly pg create`, which Fly no longer supports for unmanaged Postgres) → point `DATABASE_URL` of both apps at it → `fly deploy` with the new primary region → empty Redis. App names, and so `quiz-agent-api.fly.dev`, are global on Fly, so iOS keeps working. Expected RPO ≤ ~5 min, RTO ~1–2 h, mostly human/agent time.
- **Portability:** for a move off Fly (Hetzner or an emergency), clients need a hostname we own. Optional low-cost step: serve the API also as `api.trubbo.app` and use it in the next iOS build; 1.0/1.1 builds keep `fly.dev` until retired.

## 6. Recommended plan (207.20) — ordered small steps, each with a verify

Each step = its own PR or infra change, done and verified before the next.

1. **PITR on.** Create R2 bucket `quiz-pack-db-wal` (EU, private, no bucket lock) + a write token for the DB and a read-only token for step 2. Rehearse on a throwaway PG app from the same image (destroyed after, cents): set `archive_timeout` 300 s, then break the token and confirm the alert path and the self-heal (`archive_command` → `/bin/true`, `pg_wal` shrinks, no restart). Then set `S3_ARCHIVE_CONFIG` on `quiz-pack-db`.
   *Verify:* `flexctl backup list` shows a base backup; `pg_stat_archiver` advancing with no failures; archive size after 48 h; restore with `targetTime` = a minute after a marker row was written → marker present, row counts match prod.
2. **Archive alert/self-heal on prod + weekly automated restore.** Ops watch alert + self-heal (§3.2) go live. A weekly workflow in the private backups repo restores latest base + WAL with stock `barman-cloud-restore` (read-only token) into a plain Postgres 17 + pgvector container, the same path a region or Hetzner exit uses, and checks the newest heartbeat/marker row is ≤ 10 min old and `questions` count is sane. Keep the nightly dump.
   *Verify:* workflow green on a real run, red when pointed at an empty prefix.
3. **quiz-agent state → Postgres** (sessions with `version`, ratings, model scores, translation cache, alert state, worker ping) with every session writer going through the conditional update. Copy the few live rows at cutover (or let 70 short-lived sessions expire; the cutover deploy is itself the last outage).
   *Verify:* tests encode a duplicate submit and a TTS prefetch racing a submit across two app instances (no lost question advance); on staging with 2 machines, a quiz started on one machine continues when that machine is stopped.
4. **TTS cache → R2** with L1 + cross-machine single-flight; upload the existing 36 MB cache first so nothing is re-bought.
   *Verify:* fresh machine serves cached questions with zero ElevenLabs calls (provider-call counter unchanged); concurrent fetch on two staging machines → one synthesis.
5. **Monitors as singleton** (leader lease row).
   *Verify:* staging with 2 machines → one e-mail per alert across > 1 h idle (past the 30-min proxy timeout); `fly machine kill` (not a clean stop) of the leader → the other leads within ~2 min.
6. **Drop the volume, go to 2 machines + rolling.** Keep the old volume detached a week (its snapshots), then delete.
   *Verify:* during a deploy and during a `fly secrets set`, a probe hitting `/api/v1/health` every 0.5 s and an active staging quiz see 0 failures.
7. **Redis loss drill** on staging (DB 1): place an order, `FLUSHDB`, order still completes via the sweep.
   *Verify:* order reaches `done`, exactly one generation in the job log.
8. **Region drill** (once, then yearly): restore the R2 archive with stock barman-cloud into a Postgres machine in `ams` (or a Hetzner VM), boot a staging quiz-agent against it, play a quiz. Write the runbook section from what actually happened.
   *Verify:* measured RTO + RPO recorded in the runbook.

## 7. Monthly cost

| Item | Δ / month | Source |
|---|---|---|
| 2nd quiz-agent machine, shared-cpu-1x 512 MB always on | +$3.69 | [Fly pricing](https://fly.io/docs/about/pricing/) (US list price; EU assumed similar) |
| quiz-agent volume 3 GB removed (+ its snapshots, inside 10 GB free) | −$0.45 | Fly pricing, $0.15/GB-mo; snapshots $0.08/GB-mo over 10 GB free |
| R2: WAL + 7 daily base backups (~1–5 GB) + TTS cache (36 MB) | $0 (free tier 10 GB, 1 M writes) | [R2 pricing](https://developers.cloudflare.com/r2/pricing/) |
| Weekly restore workflow (private repo Actions minutes) | $0 (inside free minutes) | — |
| **Total** | **≈ +$3.2** | |

Hetzner comparison for later (no action): CX23 ~€5.49/mo, volumes ~€0.06/GB-mo ([Hetzner price adjustment 2026-06](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)); the design moves as is (Postgres + barman-cloud + S3-compatible storage).

## 8. Needs the founder

- **OK for +$3.69/mo** (second always-on quiz-agent machine). If no: bluegreen with one machine ($0), deploy outage still gone, host-failure risk stays.
- Nothing else: no new service, no new account (R2 is in the existing Cloudflare account), no product change.

## Sources

- Fly: [pricing](https://fly.io/docs/about/pricing/) · [configuration / deploy strategies](https://fly.io/docs/reference/configuration/#picking-a-deployment-strategy) · [deploy](https://fly.io/docs/launch/deploy/) · [unmanaged Postgres backup (archived)](https://fly.io/docs/postgres/managing/backup-and-restore/) · [HA & replication](https://fly.io/docs/postgres/advanced-guides/high-availability-and-global-replication/)
- postgres-flex: [repo](https://github.com/fly-apps/postgres-flex) · [haproxy.cfg](https://github.com/fly-apps/postgres-flex/blob/master/config/haproxy.cfg) · [PR #231 WAL archiving](https://github.com/fly-apps/postgres-flex/pull/231) · [barman.go](https://github.com/fly-apps/postgres-flex/blob/master/internal/flypg/barman.go)
- Barman cloud: [user guide 3.10](https://docs.pgbarman.org/release/3.10.0/user_guide/barman_cloud.html)
- PostgreSQL 17: [WAL config / archive_timeout](https://www.postgresql.org/docs/17/runtime-config-wal.html#GUC-ARCHIVE-TIMEOUT) · [ALTER SYSTEM](https://www.postgresql.org/docs/17/sql-altersystem.html) · [continuous archiving & PITR](https://www.postgresql.org/docs/17/continuous-archiving.html)
- Cloudflare R2: [pricing](https://developers.cloudflare.com/r2/pricing/) · [S3 API compatibility](https://developers.cloudflare.com/r2/api/s3/api/) · [bucket locks](https://developers.cloudflare.com/r2/buckets/bucket-locks/)
- SQLAlchemy: [version counter](https://docs.sqlalchemy.org/en/20/orm/versioning.html)
- Redis: [persistence](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/) · ARQ: [docs](https://arq-docs.helpmanual.io/)
- Hetzner: [2026 price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)
