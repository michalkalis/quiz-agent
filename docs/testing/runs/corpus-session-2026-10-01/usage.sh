#!/usr/bin/env zsh
# Read Claude Code subscription utilisation (five_hour / seven_day %) from the OAuth usage endpoint.
# Token comes from the macOS Keychain entry Claude Code writes; never printed. Usage: usage.sh [--loop SECONDS]
PY=/Users/agent/code/quiz-agent/.venv/bin/python
read_usage() {
  local tok
  tok=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | $PY -c 'import sys,json; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])' 2>/dev/null)
  [[ -z "$tok" ]] && { echo "$(date '+%F %T') no-token"; return 1; }
  curl -s -m 20 https://api.anthropic.com/api/oauth/usage -H "Authorization: Bearer $tok" -H "anthropic-beta: oauth-2025-04-20" \
    | $PY -c 'import sys,json,datetime; d=json.load(sys.stdin); print(datetime.datetime.now().strftime("%F %T"), "5h=%s%%" % d["five_hour"]["utilization"], "7d=%s%%" % d["seven_day"]["utilization"], "7d_reset=%s" % d["seven_day"]["resets_at"][:16])'
}
if [[ "${1:-}" == "--loop" ]]; then while true; do read_usage; sleep "${2:-120}"; done; else read_usage; fi
