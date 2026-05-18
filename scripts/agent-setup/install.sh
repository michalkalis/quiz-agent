#!/usr/bin/env bash
# Setup skript pre `agent` macOS účet.
# Spusti pod `agent` userom: bash install.sh
#
# Pred spustením skontroluj:
#   - si prihlásený ako `agent` (whoami)
#   - máš sieťové pripojenie
#   - Xcode CLI tools môžu vyžadovať jednorázový GUI confirm

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/CHANGE_ME/quiz-agent.git}"
CODE_DIR="$HOME/code"
REPO_DIR="$CODE_DIR/quiz-agent"

log() { printf "\033[1;34m[setup]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[warn]\033[0m %s\n" "$*"; }
fail() { printf "\033[1;31m[fail]\033[0m %s\n" "$*" >&2; exit 1; }

# ─── Sanity checks ─────────────────────────────────────────────
[[ "$(whoami)" == "agent" ]] || warn "Nie si 'agent' user (si '$(whoami)'). Pokračujem, ale skontroluj."
[[ "$(uname)" == "Darwin" ]] || fail "Toto je len pre macOS."

# ─── Xcode CLI tools ───────────────────────────────────────────
if ! xcode-select -p >/dev/null 2>&1; then
  log "Inštalujem Xcode Command Line Tools (môže otvoriť GUI dialóg)…"
  xcode-select --install || true
  echo "Pokračuj keď CLT skončia (Enter)…"
  read -r
fi

# ─── Homebrew ──────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  log "Inštalujem Homebrew…"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Apple Silicon brew path
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
  if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
  fi
fi

# ─── CLI packages ──────────────────────────────────────────────
log "Inštalujem CLI tools…"
brew install \
  tmux \
  mosh \
  cliclick \
  gh \
  node \
  uv \
  jq \
  ripgrep \
  fd

brew install --cask tailscale

# Fly.io CLI
if ! command -v flyctl >/dev/null 2>&1; then
  log "Inštalujem flyctl…"
  curl -L https://fly.io/install.sh | sh
  echo 'export FLYCTL_INSTALL="$HOME/.fly"' >> "$HOME/.zprofile"
  echo 'export PATH="$FLYCTL_INSTALL/bin:$PATH"' >> "$HOME/.zprofile"
  export FLYCTL_INSTALL="$HOME/.fly"
  export PATH="$FLYCTL_INSTALL/bin:$PATH"
fi

# ─── Claude Code ───────────────────────────────────────────────
log "Inštalujem Claude Code…"
npm i -g @anthropic-ai/claude-code

# ─── tmux config ───────────────────────────────────────────────
log "Píšem tmux config…"
cat > "$HOME/.tmux.conf" <<'EOF'
# Sane defaults
set -g default-terminal "screen-256color"
set -g history-limit 50000
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1

# Status bar
set -g status-bg colour235
set -g status-fg colour250
set -g status-left "[#S] "
set -g status-right "%Y-%m-%d %H:%M "

# Easier reload
bind r source-file ~/.tmux.conf \; display "tmux config reloaded"
EOF

# ─── Repo clone ────────────────────────────────────────────────
mkdir -p "$CODE_DIR"
if [[ ! -d "$REPO_DIR/.git" ]]; then
  log "Klonujem repo z $REPO_URL …"
  if [[ "$REPO_URL" == *"CHANGE_ME"* ]]; then
    warn "REPO_URL nie je nastavená. Preskakujem clone."
    warn "Spusti znovu: REPO_URL=https://github.com/user/quiz-agent.git bash install.sh"
  else
    git clone "$REPO_URL" "$REPO_DIR"
  fi
else
  log "Repo už existuje, preskakujem clone."
fi

# ─── .env šablóna ──────────────────────────────────────────────
if [[ ! -f "$HOME/.env" ]]; then
  log "Vytváram šablónu ~/.env (vyplniť ručne)…"
  cat > "$HOME/.env" <<'EOF'
# Skopíruj hodnoty z hlavného účtu. Nikdy nepushuj do git.
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
SENTRY_DSN=
FLY_API_TOKEN=
GITHUB_TOKEN=
EOF
  chmod 600 "$HOME/.env"
fi

# ─── LaunchAgent: auto-start tmux + Claude Code pri prihlásení ─
log "Inštalujem LaunchAgent (auto-start tmux pri logine)…"
LA_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$LA_DIR"
PLIST="$LA_DIR/com.agent.claude-tmux.plist"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.agent.claude-tmux</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>/opt/homebrew/bin/tmux new-session -d -s main -c $REPO_DIR</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/agent-tmux.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/agent-tmux.err</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

# ─── Zsh aliases ───────────────────────────────────────────────
log "Pridávam zsh aliases…"
ALIAS_FILE="$HOME/.zshrc"
cat >> "$ALIAS_FILE" <<'EOF'

# ─── agent setup aliases ───
alias t='tmux attach -t main || tmux new -s main'
alias cc='claude'
alias qa='cd ~/code/quiz-agent'
[ -f ~/.env ] && set -a && . ~/.env && set +a
EOF

# ─── Hotovo ────────────────────────────────────────────────────
log "✓ Done."
cat <<EOF

Ďalšie kroky (manuálne, v GUI):
  1. System Settings → Privacy & Security → Accessibility → pridaj Terminal.app
  2. System Settings → Privacy & Security → Screen Recording → pridaj Terminal.app
  3. System Settings → General → Sharing → Screen Sharing: ON, povoľ 'agent'
  4. Spusti Tailscale.app a prihlás sa
  5. Vyplň ~/.env API kľúčmi (z hlavného účtu)
  6. Pod TVOJÍM admin účtom: sudo xcodebuild -license accept
  7. Reboot a over: tmux session sa spustí automaticky

Z iPhone:
  - Termius: ssh agent@<tailscale-hostname> → 't' (attach tmux) → 'cc' (Claude)
  - Screens / VNC Viewer: vnc://<tailscale-hostname>

EOF
