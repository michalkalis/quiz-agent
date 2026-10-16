#!/usr/bin/env bash
# Install the prod watchdog on mba as a LaunchAgent (#207 — production readiness, 207.7).
#
#   scripts/mba-watchdog/install.sh            # install / update (idempotent)
#   scripts/mba-watchdog/install.sh uninstall
#
# Runs watchdog.py every 60 s in the gui domain. Config (0600) goes to
# ~/.config/trubbo-watchdog/env: SENTRY_DSN is read from the quiz-agent-api Fly
# app (founder `fly auth login`), QUIZ_PACK_ADMIN_API_KEY from the repo .env.
# Logs: ~/Library/Logs/trubbo-watchdog/watchdog.log
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL="com.missinghue.trubbo-watchdog"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
CONF_DIR="$HOME/.config/trubbo-watchdog"
LOG_DIR="$HOME/Library/Logs/trubbo-watchdog"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "uninstall" ]; then
  rm -f "$PLIST"
  echo "watchdog uninstalled"
  exit 0
fi

mkdir -p "$CONF_DIR" "$LOG_DIR" "$HOME/Library/LaunchAgents"
umask 077
dsn="$(env -u FLY_API_TOKEN fly ssh console -a quiz-agent-api -C 'printenv SENTRY_DSN' 2>/dev/null | tr -d '\r\n')"
admin_key="$(grep -E '^QUIZ_PACK_ADMIN_API_KEY=' "$REPO/.env" | head -1 | cut -d= -f2- | tr -d "\"'")"
[ -n "$dsn" ] || { echo "could not read SENTRY_DSN from quiz-agent-api (fly auth login?)" >&2; exit 1; }
[ -n "$admin_key" ] || { echo "QUIZ_PACK_ADMIN_API_KEY missing in $REPO/.env" >&2; exit 1; }
printf 'SENTRY_DSN=%s\nQUIZ_PACK_ADMIN_API_KEY=%s\n' "$dsn" "$admin_key" >"$CONF_DIR/env"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-I</string>
    <string>$REPO/scripts/mba-watchdog/watchdog.py</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIR/watchdog.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/watchdog.log</string>
</dict></plist>
EOF
launchctl bootstrap "$DOMAIN" "$PLIST"
/usr/bin/python3 -I "$REPO/scripts/mba-watchdog/watchdog.py" --all
/usr/bin/python3 -I "$REPO/scripts/mba-watchdog/watchdog.py" --test-alert
echo "watchdog installed ($LABEL); a test alert was sent to Sentry — expect one e-mail"
