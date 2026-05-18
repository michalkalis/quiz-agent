# Setup: `agent` macOS account na MBA M3

Sandboxovaný macOS účet pre Claude Code s remote access (SSH + VNC) z iPhonu.

**Cieľ:** Claude Code beží 24/7 v sandboxe, nemá prístup k tvojím dátam, vie ovládať Mac, ty sa pripojíš z telefónu kedykoľvek.

---

## Pred štartom — rozhodnutie o FileVault

Auto-login a FileVault sa **vylučujú**. Máš dve cesty:

| Cesta | FileVault | Auto-login | Bezpečnosť | Pohodlie |
|-------|-----------|------------|------------|----------|
| **A. FileVault ON** | ✅ disk šifrovaný | ❌ — pri reboote musíš zadať heslo raz | Vyššia | Po reštarte 1× login |
| **B. FileVault OFF** | ❌ disk čitateľný ak ho niekto vyberie | ✅ true auto-login | Nižšia | Plný 24/7 unattended |

**Odporúčam cestu A** — strata pohodlia je 5 sekúnd raz za týždeň (reštart), bezpečnostný zisk je veľký. Tmux + LaunchAgent zariadia, že po prihlásení sa Claude Code spustí sám.

Ak chceš cestu B (true auto-login, ako si vybral), prepni FileVault na MBA OFF: `System Settings → Privacy & Security → FileVault → Turn Off`.

---

## Fáza 1 — Vytvorenie účtu (pod tvojím účtom)

1. **System Settings → Users & Groups → Add User…**
   - Type: **Standard** (NIE Administrator)
   - Full name: `Agent`
   - Account name: `agent`
   - Password: silné, ulož do 1Password
   - "Allow user to administer this computer": **OFF**

2. **Enable auto-login** (pre `agent`)
   - System Settings → Users & Groups → Automatically log in as: `agent`
   - Vyžaduje vypnutý FileVault (pozri vyššie)

3. **Fast User Switching** (užitočné aj s auto-login)
   - System Settings → Control Center → Fast User Switching → "Show in Menu Bar"

4. **Reštartuj Mac** → automaticky sa prihlási `agent`

---

## Fáza 2 — Setup skript (pod `agent` účtom)

Prihlás sa do `agent`, otvor Terminal a spusti:

```bash
curl -fsSL https://raw.githubusercontent.com/<tvoj-username>/quiz-agent/main/scripts/agent-setup/install.sh | bash
```

Alebo ak repo ešte nemáš pushnuté, manuálne:

```bash
# Stiahni skript priamo
cd ~ && mkdir -p Downloads
# (skopíruj install.sh do ~/Downloads/install.sh)
bash ~/Downloads/install.sh
```

Skript robí:
- Inštaluje Homebrew + CLI tools (tmux, mosh, cliclick, gh, flyctl, uv, node)
- Inštaluje Claude Code (`npm i -g @anthropic-ai/claude-code`)
- Klonuje `quiz-agent` repo do `~/code/quiz-agent`
- Nastaví tmux config + zsh aliases
- Vytvorí LaunchAgent ktorý spustí tmux session pri prihlásení

---

## Fáza 3 — macOS Permissions (manuálne, GUI)

Toto sa **nedá skriptovať** — Apple TCC vyžaduje user consent.

### 3.1. Screen Sharing (VNC z iPhonu)
- System Settings → General → Sharing → **Screen Sharing: ON**
- "Allow access for: Only these users" → `agent`
- (voliteľné) "Computer Settings…" → VNC password pre non-Apple klientov

### 3.2. Accessibility (klikanie cez cliclick/osascript)
- System Settings → Privacy & Security → **Accessibility**
- `+` → pridaj: `Terminal.app` (alebo iTerm), `cliclick`

### 3.3. Screen Recording (potrebné pre niektoré accessibility ops)
- Privacy & Security → **Screen Recording**
- `+` → `Terminal.app`

### 3.4. Automation
- Privacy & Security → **Automation**
- Pri prvom `osascript` volaní macOS sa spýta — povoľ

### 3.5. Full Disk Access (len ak Claude potrebuje)
- Privacy & Security → **Full Disk Access**
- `+` → `Terminal.app` (zváž — ruší časť sandbox výhod)

### 3.6. Xcode license
```bash
sudo xcodebuild -license accept   # vyžaduje sudo → ale agent NIE JE admin
```

**Problém:** `agent` nemá sudo. Riešenia:
- **A.** Pod tvojím účtom raz spusti `sudo xcodebuild -license accept` — licencia je system-wide
- **B.** Dočasne pridaj `agent` do `admin` skupiny, akceptuj licenciu, odober

---

## Fáza 4 — Network (Tailscale)

### 4.1. Inštalácia
```bash
brew install --cask tailscale
open -a Tailscale
# Klikni "Log in" → použi rovnaký Tailscale account ako na iPhone
```

### 4.2. Overenie
```bash
tailscale status              # vidíš Mac aj iPhone
tailscale ip -4               # tvoja Tailscale IP (100.x.x.x)
```

### 4.3. Magic DNS (pohodlnejšie)
- Tailscale admin console → DNS → enable "MagicDNS"
- Potom môžeš použiť hostname: `ssh agent@mba-m3` namiesto IP

---

## Fáza 5 — Z iPhonu

### 5.1. Termius (SSH + tmux)
- App Store: **Termius**
- Hosts → New Host:
  - Hostname: Tailscale IP alebo MagicDNS hostname
  - Username: `agent`
  - Password: heslo z 1Password
- Konekt → otvorí sa terminal → `tmux attach -t main` → si v Claude Code session

### 5.2. Screens (VNC s klikaním)
- App Store: **Screens** ($20) — najlepší VNC, alebo zdarma **VNC Viewer**
- New Screen:
  - Address: Tailscale IP
  - Username: `agent`
  - Password: macOS user password
- Otvorí desktop, vidíš čo Claude robí, môžeš klikať

---

## Verifikácia (checklist)

- [ ] `agent` účet existuje, Standard type, NIE admin
- [ ] Auto-login funguje (po reboote sa Mac prihlási do `agent`)
- [ ] `agent` nevidí `/Users/michalkalis/Documents/` (test: `ls /Users/michalkalis/Documents` → Permission denied)
- [ ] Homebrew + Claude Code nainštalované pod `agent`
- [ ] `claude` v termináli pod `agent` funguje
- [ ] Tailscale beží, Mac viditeľný z iPhonu
- [ ] Termius sa pripája cez Tailscale
- [ ] Screens / VNC ukazuje desktop, dá sa klikať
- [ ] tmux session sa spúšťa pri prihlásení (LaunchAgent)
- [ ] `xcrun simctl list devices` funguje pod `agent`
- [ ] `cliclick m:.` funguje (test klikania)

---

## Bezpečnostné poznámky

1. **`agent` nemá sudo** — toto je hlavná obrana. Neprideľuj mu admin práva ani dočasne, leda na ojedinelé taskoy a hneď odober.
2. **API kľúče v `~/.env`** pod `agent`, `chmod 600`. NIKDY do git.
3. **Tailscale ACL** — môžeš zúžiť: iPhone → Mac len SSH+VNC, nič iné.
4. **Screen Sharing password ≠ login password** — odporúčam mať odlišné.
5. **Bez FileVault** disk je čitateľný keď Mac vypneš a vyberieš SSD. Pre MBA s lockom (Activation Lock) je riziko nízke, ale nenulové.

---

## Zostávajúce open questions

- **Notifikácie z agenta na iPhone**: chcem `ntfy.sh` (push notif keď Claude čaká). Doplníme v ďalšom kroku.
- **TestFlight upload**: vyžaduje App Store Connect API key — uložiť pod `agent` v `~/.fastlane/`.
- **Sentry, OpenAI, Anthropic API keys**: skopírovať z hlavného účtu do `~/.env` pod `agent`.
