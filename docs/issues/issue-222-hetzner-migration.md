# #222 — Presun backendu z Fly.io na Hetzner

**Triage:** chore · ready-for-agent
**Status:** 2026-11-02 founder: presunúť na Hetzner, údržbu (zálohy, aktualizácie, dohľad) robí agent; server vytvára agent; Fly zrušiť po skončení App Store review. Founder má Hetzner účet.
**Súvisí:** #217 — verejné vydanie v App Store · [analýza nákladov](../research/hetzner-migration-cost-2026-11-02.md)

## Cieľ

Celý backend (quiz-agent, quiz-pack web + worker, Postgres/pgvector, Redis) beží na jednom Hetzner serveri (Docker Compose + Caddy). Hráč nespozná rozdiel okrem rýchlejšieho prvého načítania. Fly ostane len ako malý presmerovač pre staré buildy, potom zmizne úplne.

**Hotové =** prod na Hetzneri ≥ 7 dní bez incidentu, zálohy + skúšobná obnova zelené, Fly účet len presmerovač (alebo prázdny), účet Fly ≤ ~$3/mes.

## Časovanie (rozhodnuté agentom 2026-11-02)

- **Počas App Store review sa prod nedotýkame.** Recenzenti Apple hrajú proti `*.fly.dev`; žiadna odstávka ani zmena DB, kým review nezbehne. 222.1–222.5 prod nemenia, idú hneď.
- **Prepnutie (222.6) až po schválení 1.1**, v tichej hodine (ráno, najmenej hráčov podľa analytiky), nie v deň vydania.
- **Na deň vyúčtovania Fly netreba čakať:** Fly účtuje za skutočné využitie po sekundách (stroje) a hodinách (disky), bez záväzku, faktúra mesačne. Čo zmažeme, prestane stáť hneď.
- **Fly sa nedá zrušiť celé hneď po review:** build 1.1 v review má natvrdo `quiz-agent-api.fly.dev` / `quiz-pack-api.fly.dev`. Tie adresy musia odpovedať, kým hráči neprejdú na build s vlastnou doménou (222.5) a min-verzia v `/app-config` staré buildy nevypne.

## Kroky

| # | Krok | Dotýka sa produ? |
|---|---|---|
| 222.1 | **Server:** Hetzner API token od foundera do `.env` (`HCLOUD_TOKEN`), agent vytvorí CX23 (Nuremberg/Falkenstein, Ubuntu 24.04, kľúč `~/.ssh/trubbo_hetzner`); Hetzner firewall (22 len kľúč, 80/443), unattended-upgrades, fail2ban, Docker, Caddy. Ak CX23 nedostupný: iná lokalita → CX33 → plán B z analýzy | nie |
| 222.2 | **Stack + skúška:** Compose (agent, pack web, pack worker, `pgvector/pgvector:pg17`, Redis 8), obnova z poslednej šifrovanej zálohy, testovacia adresa mimo appky; smoke testy oboch API | nie |
| 222.3 | **Kód nezávislý od Fly (spätne kompatibilný):** IP klienta pre limity aj z hlavičky od Caddy (inak všetci hráči zdieľajú jeden limit), uvicorn proxy hlavičky, ops_watch/provider_costs bez Fly metrík, URL v monitoringu/skriptoch z konfigurácie; funguje na Fly aj Hetzneri | nasadenie bez zmeny správania |
| 222.4 | **Prevádzka:** nasadzovanie z CI (obrazy do GHCR + SSH `compose pull/up`, migrácie samostatný krok, smoke), nočná šifrovaná záloha priamo zo servera + WAL do R2, týždenná skúšobná obnova, upozornenie na disk/pamäť/výpadok; tunel pre mba worker cez SSH | nie |
| 222.5 | **Vlastná doména:** `api.trubbo.app` + `pack.trubbo.app` (DNS u GoDaddy) do `Prod.xcconfig` → ide s najbližším buildom po 1.1; zatiaľ ukazuje na Fly, po 222.6 na Hetzner | nie (len DNS) |
| 222.6 | **Prepnutie (po schválení 1.1):** údržbový režim zap → finálny dump/restore (~15–30 min) → Fly appky nahradí presmerovač (Caddy 256 MB) na Hetzner → doména na Hetzner → App Store Server Notifications URL v ASC → smoke → údržba vyp. Fly DB a Redis ostanú zastavené 7 dní ako návrat späť | **áno** |
| 222.7 | **Upratanie Fly:** po 7 dňoch zmazať DB, Redis, worker, staging (staging brána presunutá na Hetzner v 222.4); presmerovač zrušiť, keď min-verzia vypne buildy s fly.dev | áno (len mazanie) |

## Návrat späť (222.6)

Do 7 dní: presmerovač aj doména späť na Fly stroje, Fly DB naštartovať; dáta zapísané na Hetzneri medzitým exportovať späť (objednávky, nákupy). Po 7 dňoch len obnova zo zálohy.

## Riziká

- Platobné notifikácie od Apple počas prepnutia → Apple ich opakuje, plus `reconcile` po prepnutí.
- Jeden server = jeden bod zlyhania → záloha mimo servera + overená obnova; obnova = nový server + restore (hodiny).
- Hetzner obmedzuje nové servery (od 2026-06-26) → 222.1 overí hneď na začiatku.

## Založenie servera — potrebné od foundera

API token (raz): Hetzner Console → projekt → **Security** → **API tokens** → **Generate API token**, oprávnenie **Read & Write** → hodnotu vložiť do root `.env` ako `HCLOUD_TOKEN=...` (nie do chatu).
