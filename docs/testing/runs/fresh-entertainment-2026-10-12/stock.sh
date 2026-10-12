#!/usr/bin/env zsh
# #199 stock check on prod (same counting as the daily Sentry check): fresh = approved entertainment
# rows whose boost_until runs past now+14 days but is not permanent. Prints one line per language.
set -u
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
curl -sf -H "X-Admin-Key: $ADMIN_API_KEY" https://quiz-agent-api.fly.dev/api/v1/admin/question-stock \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); t=r["thresholds"]; print("thresholds", t)
for l in r["languages"]: print(l["language"], "fresh", l["fresh_entertainment"], "entertainment", l["categories"].get("entertainment"))
print("alerts:", [(a["language"], a["category"], a["count"]) for a in r["alerts"]])'
