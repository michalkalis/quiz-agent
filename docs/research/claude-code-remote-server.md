# Research: Claude Code na vzdialenom serveri

**Dátum:** 2026-05-16 | **Otázka:** Má zmysel a je to bežná prax spúšťať Claude Code na hostovanom VPS a pristupovať k nemu vzdialene?

---

## Zhrnutie (TL;DR)

- **Áno, je to bežná a rastúca prax** — existujú desiatky návodov, GitHub projektov a platených platforiem len pre tento prípad.
- Štandardný stack: **Ubuntu VPS + tmux + SSH + Tailscale + Termius** (iOS app) — hotový za ~2 hodiny, cena $25–30/mesiac.
- Anthropic sám spustil **claude.ai/code** — oficálne cloudové prostredie pre Claude Code (od Max plánu ~$100/mesiac).
- Pre tvoj cieľ (prompt z telefónu → auto-implementácia → auto-deploy) je **VPS s tmux + ntfy notifikáciami** ideálne riešenie.

---

## Hlavné zistenia

### 1. Bežnosť praxe

Spúšťanie Claude Code na VPS je v 2025–2026 **mainstreemová prax**. Dôvody:
- Claude Code samo o sebe je len CLI — inference beží na Anthropic serveroch, nie lokálne. VPS môže byť aj slabý (2 vCPU, 4 GB RAM).
- Vývojári chcú: **persistentné sessions** (laptop môžu zatvoriť), **prístup z telefónu**, **paralelné agenty**, **úlohy bežiace v noci**.

### 2. Typy riešení (od jednoduchého k sofistikovanému)

| Riešenie | Cena/mesiac | Čas nastavenia | Vhodné pre |
|----------|-------------|----------------|------------|
| **Vlastný VPS (Hetzner/DO)** | $5–15 (VPS) + $20 (Claude Pro) | 2–4 hod | Solo dev, max kontrola |
| **Managed platforma (Duet, Shipyard)** | $50–200/user | 5 min | Tím, žiadna infra |
| **claude.ai/code** (Anthropic cloud) | zahrnuté v Max ($100–200) | 0 min | Offloading na Anthropic |
| **Homelab (vlastný server doma)** | ~$0 (ak máš HW) | 3–6 hod | Power users |

### 3. Technická realizácia — VPS stack

Štandardný odporúčaný stack pre solo dev:

```
iPhone / Android
   ↓  (SSH cez Tailscale VPN)
Termius (mobil SSH klient)
   ↓
Ubuntu VPS (Hetzner CAX11: 2 vCPU, 4 GB, $4.5/mes)
   ↓
tmux session  →  Claude Code
   ↓
ntfy.sh (push notifikácie keď Claude čaká na vstup)
```

**Kľúčové komponenty:**

- **tmux** — session prežije zatvorenie telefónu, prerušenie spojenia. `Ctrl+B D` = odpojiť, `tmux attach` = pripojiť späť.
- **Tailscale** — VPN overlay sieť (zadarmo pre solo), SSH port nie je vystavený internetu. Funguje cez NAT.
- **mosh** — alternatíva k SSH, odolná voči výpadkom wifi→4G, UDP-based. Kombinuje sa s tmux.
- **ntfy.sh** — open-source push notifikácie. Claude Code hook → HTTP call → notifikácia na telefóne.
- **Termius** (iOS/Android) — SSH klient, podporuje Tailscale IP, rozumný mobilný terminál.

### 4. Anthropic cloud riešenia (oficálne)

Anthropic v 2025 spustil vlastné cloudové riešenia:

**claude.ai/code (Claude Code Remote)**
- Kontajnerizované prostredie, predkonfigurované (Python, Node, Go...)
- "Teleport" — spusti task z laptopa, pokračuj na telefóne
- Paralelné agenty bez vlastnej infraštruktúry
- Potrebuje **Claude Max** ($100–200/mesiac)

**Scheduled Tasks** (v claude.ai/code)
- Definuj prompt + cron schedule → Claude spúšťa úlohy automaticky
- Ideálne pre generovanie otázok, nočné buildy, atď.

**Agent SDK Hosting** (pre vývojárov)
- Anthropic API + ich managed runtime
- Pre vlastné agentové aplikácie, nie len interaktívny Claude Code

### 5. Mobilný prístup — realita

Blog post "Claude Code from the beach" (2026-02) dokumentuje reálny workflow:
1. Otvoriš Termius na iPhone → pripojíš sa na VPS cez Tailscale
2. `tmux attach` → si v session kde Claude Code beží
3. Zadáš prompt, vložíš telefón do vrecka
4. Keď Claude čaká na tvoj vstup → ntfy notifikácia na telefóne
5. Odpovieš, vložíš naspäť

**Funguje to.** Mosh rieši nestabilné mobilné spojenie, tmux rieši persistenciu session.

### 6. Bezpečnosť

Hlavné riziká a ako ich mitiguvať:

| Riziko | Mitigácia |
|--------|-----------|
| API kľúče na serveri | `.env` súbory, nikdy v git; `chmod 600` |
| SSH port na internete | Tailscale VPN — SSH dostupný len cez private sieť |
| Claude má prístup k celému filesystému | Dedikovaný user, len projektový adresár |
| Kompromitovaný server | Pravidelné updates, Fail2Ban, UFW firewall |

### 7. Náklady

**Minimálna konfigurácia (odporúčaná):**
- Hetzner CAX11 (Arm64, 2 vCPU, 4 GB): ~$4.5/mes
- Claude Pro: $20/mes
- Tailscale: zadarmo (do 3 zariadení)
- ntfy.sh: zadarmo (self-hosted) alebo $5/mes (cloud)
- **Celkom: ~$30/mes**

Vs. lokálne: $0 ďalšie náklady, ale laptop musí byť zapnutý.

---

## Dôsledky pre Quiz Agent projekt

Tvoj cieľ: "prompt z telefónu → auto-implementácia → auto-deploy do TestFlight/Fly.io"

**VPS + tmux + ntfy je priamo navrhnuté pre tento use case.** Konkrétne:

1. VPS beží 24/7 → Claude Code beží v tmux session
2. Pošleš prompt z Termius na iPhone
3. Claude implementuje feature, spustí testy, deployuje na Fly.io
4. ntfy notifikácia: "Deploy dokončený" alebo "Potrebujem rozhodnutie"
5. Ty schváliš/odmietneš cez telefón

Pre **iOS builds (TestFlight)** je situácia iná — Xcode musí bežať na macOS. Tu by si potreboval:
- **macOS VM** (drahšie, MacStadium ~$100/mes) alebo
- **GitHub Actions** (ako teraz) — CI robí build, Claude Code len commituje

**Odporúčanie pre teba:**
1. Krátkodobo: zostať pri lokálnom Claude Code + GitHub Actions pre CI
2. Strednodobo: VPS (Hetzner) pre backend agenta — generovanie otázok, Fly.io deploy, bez potreby laptopa
3. Dlhodobo: ak chceš full autonomy, macOS Mini M4 doma + Tailscale + tmux — náklady $0/mes (po HW)

---

## Odporúčania

1. **Začni VPS-om pre backend tasks** — Fly.io deploye, generovanie otázok, quiz-pack-api. Hetzner CAX11 za $4.5/mes.
2. **Nastav ntfy.sh hooks** — Claude Code vie zavolať webhook pri approvala, completion, error. Notifikácia na telefóne.
3. **Tailscale namiesto expozície SSH** — bezpečnejší ako firewall rules, zadarmo.
4. **iOS builds nechaj na GitHub Actions** — macOS na VPS nie je realistické, CI je správna voľba.
5. **claude.ai/code (Max plán) zvážiť neskôr** — ak potrebuješ paralelné agenty bez ops záťaže.

---

## Zdroje

1. [Claude Code On a VPS: The Complete Setup](https://medium.com/@0xmega/claude-code-on-a-vps-the-complete-setup-security-tmux-mobile-access-2d214f5a0b3b) — kompletný návod: security, tmux, mobilný prístup
2. [How to Run Claude Code in the Cloud (24/7)](https://duet.so/blog/how-to-run-claude-code-in-the-cloud) — porovnanie managed vs self-hosted
3. [Run Claude Code from Your Phone Securely](https://www.twingate.com/blog/claude-code-termius-tmux) — Termius + Tailscale setup
4. [247 Claude Code Remote (GitHub)](https://github.com/QuivrHQ/247-claude-code-remote) — open-source web terminal pre Claude Code
5. [Claude Code from the beach](https://rogs.me/2026/02/claude-code-from-the-beach-my-remote-coding-setup-with-mosh-tmux-and-ntfy/) — reálny workflow: mosh + tmux + ntfy
6. [Shipyard + Claude Code on the web](https://shipyard.build/blog/claude-code-on-the-web/) — Anthropic cloud sessions, mobilný prístup
7. [Claude Code VPS Setup Guide](https://claudefa.st/blog/guide/development/infraops-vps-guide) — infraops perspektíva
8. [Claude Managed Agents Docs](https://platform.claude.com/docs/en/managed-agents/overview) — Anthropic oficálna dokumentácia
