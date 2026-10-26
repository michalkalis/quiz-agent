#!/usr/bin/env zsh
# One tiny embedding call — prints only the HTTP status and error code (no secrets).
set -u
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
curl -s -o /tmp/oa_check.json -w "%{http_code}\n" https://api.openai.com/v1/embeddings \
  -H "Authorization: Bearer $OPENAI_API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"text-embedding-3-small","input":"ping"}'
python3 -c "import json;d=json.load(open('/tmp/oa_check.json'));print(d.get('error',{}).get('code','ok'))"
rm -f /tmp/oa_check.json
