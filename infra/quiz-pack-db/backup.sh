#!/usr/bin/env bash
# Encrypted logical backup of quiz-pack-db (#193 — beta hardening, task 193.4).
#
# Dump AND encryption both run on the DB machine: pg_dump is piped straight
# into `openssl cms -encrypt` there, so only ciphertext ever crosses the wire
# and nothing in plaintext touches a disk outside Fly. Encryption is to a
# public X.509 certificate (the private key is kept offline by the founder),
# so the machine running this script can write backups but never read them.
#
# Usage: BACKUP_CERT_B64=<base64 of the PEM cert> infra/quiz-pack-db/backup.sh <out.cms>
# Needs `fly` on PATH and a token that can SSH into quiz-pack-db
# (`fly tokens create ssh -a quiz-pack-db`). Restore: docs/setup/db-backup.md.
set -euo pipefail

out="${1:?usage: backup.sh <output-file>}"
cert_b64="${BACKUP_CERT_B64:?BACKUP_CERT_B64 (base64 of the recipient PEM cert) is required}"
app="${DB_APP:-quiz-pack-db}"
db="${DB_NAME:-quiz_pack}"

# base64 alphabet only, so it can sit inside the single-quoted remote script.
if [[ ! "$cert_b64" =~ ^[A-Za-z0-9+/=]+$ ]]; then
  echo "BACKUP_CERT_B64 must be single-line base64" >&2
  exit 1
fi

# Runs on the DB machine. pipefail: a failing pg_dump must fail the whole
# command instead of shipping a truncated-but-valid-looking ciphertext.
remote="bash -c 'set -o pipefail; pg_dump -p 5433 -U postgres -d ${db} --format=custom --compress=9 | openssl cms -encrypt -binary -stream -aes256 -outform DER -recip <(echo ${cert_b64} | base64 -d)'"

if ! fly ssh console -a "$app" --pty=false -C "$remote" > "$out"; then
  echo "dump/encrypt failed on ${app}" >&2
  rm -f "$out"
  exit 1
fi

# From here on, "file exists" means "valid encrypted backup": every check
# that rejects the output also deletes it, so the caller can upload blindly.
# Fail loud on anything that is not ciphertext: a custom-format dump starts
# with the PGDMP magic, and its table of contents names our tables in clear.
size=$(wc -c < "$out" | tr -d ' ')
if [[ "$size" -lt 100000 ]]; then
  echo "backup suspiciously small (${size} bytes)" >&2
  rm -f "$out"
  exit 1
fi
if head -c 5 "$out" | grep -q PGDMP || grep -aq generation_orders "$out"; then
  echo "output is NOT encrypted, refusing to keep it" >&2
  rm -f "$out"
  exit 1
fi
echo "encrypted backup written: ${out} (${size} bytes)"

# The 1 GB volume has no auto-extend (a Fly Postgres machine only gets that
# through a restarting machine update). Fail the nightly run before it fills
# up so the failure email doubles as the disk alarm; the backup above is
# already valid and gets uploaded regardless.
used=$(fly ssh console -a "$app" --pty=false -C "df --output=pcent /data" | tr -dc '0-9')
echo "quiz-pack-db /data used: ${used}%"
if [[ -z "$used" || "$used" -ge "${DISK_ALERT_PERCENT:-80}" ]]; then
  echo "quiz-pack-db volume at ${used:-unknown}% — extend it (docs/setup/db-backup.md)" >&2
  exit 2
fi
