#!/bin/sh
# #210 (marketing on social networks): start the social-publish workflow on time.
# GitHub fires the workflow's hourly schedule only every 4–9 h (seen 2026-11-17),
# so posts went out hours late. The server's cron calls this at :05 every hour:
#   5 * * * * $HOME/trubbo/bin/social-publish-trigger.sh
# The workflow's own schedule stays as a fallback; publishing is idempotent.
# Token: fine-grained GitHub token, this repo only, Actions read+write, in
# ~/trubbo/repo/infra/hetzner/env/github-dispatch.env (GITHUB_DISPATCH_TOKEN=…,
# mode 600). Never printed.
set -eu
. "$HOME/trubbo/repo/infra/hetzner/env/github-dispatch.env"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $GITHUB_DISPATCH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/michalkalis/quiz-agent/actions/workflows/social-publish.yml/dispatches \
  -d '{"ref":"main","inputs":{"mode":"publish"}}')
[ "$code" = 204 ] || { echo "social-publish dispatch failed: HTTP $code" >&2; exit 1; }
