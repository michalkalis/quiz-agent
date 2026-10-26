#!/usr/bin/env zsh
# Prints ONLY the host:port and query of PROD_DATABASE_URL (no credentials) — to confirm which host laptop scripts dial.
set -u
set -a; source /Users/michalkalis/Documents/personal/ai-developer-course/code/quiz-agent/.env; set +a
python3 - <<'EOF'
import os
from urllib.parse import urlsplit
u = urlsplit(os.environ["PROD_DATABASE_URL"])
print("scheme:", u.scheme, "host:", u.hostname, "port:", u.port, "query:", u.query)
EOF
