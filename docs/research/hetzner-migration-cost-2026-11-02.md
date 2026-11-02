# Moving the backend from Fly.io to Hetzner: cost analysis (2026-11-02)

Question from the founder: the Fly.io bill (~$18/mo) feels high. Does a move to Hetzner pay off if the agent handles ops itself (backups, OS updates, monitoring)?
Earlier decisions: [[project-hosting-platform-decision]] (2026-07-05 Hetzner = target; 2026-07-17 "stay for now").

## 1. What the Fly bill is made of today

These are live machines. Prices are Fly list prices, with Paris (cdg) about 15% above the US list ([docs.fly.io/about/pricing](https://docs.fly.io/about/pricing)).

| What | Size | Runs | ~$/mo |
|---|---|---|---|
| quiz-agent-api (live quiz) | 512 MB | 24/7 (min 1) | ~4 |
| quiz-pack-api web | 512 MB | "auto-stop", but gets woken within seconds, so close to 24/7 | ~2–4 |
| quiz-pack-api worker (arq orders) | 512 MB | 24/7 | ~4 |
| quiz-pack-db (Postgres + pgvector) | 1 GB + 3 GB volume | 24/7 | ~8 |
| quiz-pack-redis | 256 MB + 1 GB | 24/7 | ~2.5 |
| staging apps (CI deploy gate) | stopped, 1 GB volume | minutes per deploy | <1 |
| **Total** | | | **~$18 ≈ €15.5** (matches the invoice) |

- The 50 GB remote builder volume is **not billed** ("There's currently no charge for builders"), so deleting it is cleanup only.
- No paid IPv4 and no paid add-ons. The Upstash staging Redis is pay-as-you-go and costs $0 when idle.
- The bill went up from ~$11 to ~$18 because Redis and the always-on worker were added in July.

## 2. Target on Hetzner (or an equivalent)

All of it fits on one VPS with Docker Compose: Caddy (TLS) + quiz-agent + pack web + pack worker + Postgres/pgvector + Redis. That totals about 2.8 GB of allocated RAM on Fly today.

| Option | vCPU / RAM / disk | €/mo excl. VAT | ~€/mo with 23% SK VAT |
|---|---|---|---|
| Hetzner CX23 (x86) | 2 / 4 GB / 40 GB | 5.99 | 7.4 |
| Hetzner CX33 (x86) | 4 / 8 GB / 80 GB | 8.99 | 11.1 |
| Hetzner backups add-on | 20% of the server | +1.2 / +1.8 | |
| netcup VPS 500 G12.5 (plan B) | 2 / 4 GB / 64 GB | 8.26 (12-month term) | ~10.2 |
| netcup VPS 1000 G12.5 | 4 / 8 GB / 128 GB | 14.50 | ~17.8 |

Sources: [hetzner.com/cloud/cost-optimized](https://www.hetzner.com/cloud/cost-optimized/), [netcup.com/en/server/vps](https://www.netcup.com/en/server/vps). Netcup's page shows gross prices with German VAT; if we invoice as a company with a VAT ID, the reverse charge applies.

**Blocker: Hetzner cannot sell new cloud servers right now.** [status.hetzner.com](https://status.hetzner.com/) has listed "Limited availability of cloud instances" since 2026-06-26. Every Cost-Optimized and Regular Performance plan page says "This product is currently unavailable". Third-party trackers show it unchanged through 2026-10-20 ([findstack](https://findstack.com/resources/hetzner-price-increase-2026)). Some existing customers can still create servers, so it is worth trying in the console. Netcup can be ordered today.

Recommended size: **CX23 (4 GB)** is enough for today's load. CX33 is the safe choice if heavy backfills should run on the same box.

## 3. Monthly saving

| Scenario | Fly | New | Saving/mo | Per year |
|---|---|---|---|---|
| CX23 + small Fly forwarder (transition) | €15.5 | €7.4 + ~€2.2 | ~€6 | ~€70 |
| CX23 alone (old builds retired) | €15.5 | €7.4 | ~€8 | ~€97 |
| CX33 alone | €15.5 | €11.1 | ~€4.5 | ~€53 |
| netcup VPS 500 alone | €15.5 | €10.2 | ~€5 | ~€64 |

**Why a forwarder:** every live iOS build has `quiz-agent-api.fly.dev` and `quiz-pack-api.fly.dev` compiled in, and the server cannot change that URL. A `*.fly.dev` name cannot be pointed elsewhere by DNS. So:
1. Ship a build that uses our own domain (e.g. `api.trubbo.app`).
2. Keep a tiny Fly app (256 MB Caddy) that forwards fly.dev traffic to the VPS.
3. Delete that app once the min-version switch in `/app-config` has retired the old builds.

## 4. One-time migration work (agent effort, not calendar time)

| Phase | Content | Effort |
|---|---|---|
| 1. Server | Provision, SSH keys only, firewall, unattended-upgrades, fail2ban, Docker, Caddy + domain/TLS | small |
| 2. Data | Postgres → `pgvector/pgvector:pg17`, dump/restore (~hundreds of MB, **15–30 min of downtime**), Redis; switch the nightly encrypted dump + WAL archive to R2 from `fly ssh` to direct; keep the weekly restore drill | medium |
| 3. Pipeline | CI: image build to GHCR + deploy over SSH (`compose pull/up`), migrations as their own step (no Fly `release_command`); smoke tests; staging as a second Compose stack on the same box or dropped | medium |
| 4. Code tied to Fly | Client IP for rate limiting (`Fly-Client-IP` → proxy header, otherwise **all players share one limit**); ops_watch/provider_costs read Fly metrics → node metrics; prod-monitor + scripts use fly.dev URLs; mba worker tunnels (`fly proxy`) → SSH tunnel; `fresh-topup` one-off machines → `docker run` | medium |
| 5. Cutover | App Store Server Notifications URL in ASC, new iOS build with our domain, Fly forwarder, then retire old builds and delete the Fly apps | small, but spread over weeks (waiting for players to update) |

In total this is about **one bigger issue (5 PRs, several sessions)**. Phases 2 and 4 carry the risk: data, the payment webhook, rate limiting.

## 5. What we gain and lose

**Gains:**
- 4–8 GB of RAM instead of 512 MB per process, so no OOM crashes (the 2026-10-22 backfill that crashed the worker).
- No cold start of pack-api.
- Heavy scripts run directly on the box.
- A flat, predictable price.

**Losses / new risks:**
- **One box = one point of failure.** If the host dies, recovery is a restore from backup (hours). Fly today is also one machine per app, but Fly moves a dead machine automatically.
- No zero-downtime bluegreen deploys out of the box; each deploy has a few seconds of downtime unless we add a rolling setup in Caddy.
- No automatic volume snapshots; our own dump + WAL become the only backup, so the restore drill must stay green.
- Ongoing ops are automatable (security updates, renewals, monitoring). The agent handles them, but someone has to watch them, and alerts must reach the founder.

## 6. Recommendation

- Money alone pays little: **~€6–8/mo (~€70–100/yr)**, set against a sizeable one-time migration and a temporary forwarder.
- What does justify the move: RAM headroom, no cold starts, flat cost.
- **If we go:** Hetzner CX23 when the founder's account can create a server; otherwise netcup VPS 500 (saves ~€5/mo, 12-month term).
- **Order of work:**
  1. Ship our own domain in the iOS build first; that is useful even without a move.
  2. Then phases 1–4.
  3. Cutover in a quiet window.
- **Do not start before the 1.1 launch (#217 — launch).** The migration touches payments and data, and the launch is the riskier moment.
