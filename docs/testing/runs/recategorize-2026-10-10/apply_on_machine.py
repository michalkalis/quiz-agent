"""Apply apply_payload.json via the admin set-category endpoint.

Run on a quiz-agent-api machine (ADMIN_API_KEY in env); payload on stdin.
Only `category` changes; the endpoint rejects ids outside the 7-id taxonomy.
"""
import json
import os
import sys
import urllib.request

req = urllib.request.Request(
    "http://localhost:8002/api/v1/admin/questions/set-category",
    data=sys.stdin.buffer.read(),
    headers={"X-Admin-Key": os.environ["ADMIN_API_KEY"], "Content-Type": "application/json"},
)
print(json.load(urllib.request.urlopen(req, timeout=120)))
