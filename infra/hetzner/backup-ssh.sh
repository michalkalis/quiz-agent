#!/usr/bin/env bash
# Forced command for the nightly-backup SSH key on the Hetzner server
# (#222 — moving the backend to Hetzner). In ~/.ssh/authorized_keys:
#   command="/home/trubbo/trubbo/repo/infra/hetzner/backup-ssh.sh",restrict ssh-ed25519 AAAA… quiz-pack-db-backup
# The key can only produce an encrypted dump or report disk usage; it cannot
# open a shell, forward ports or read anything in plaintext.
# The recipient cert is public (private key stays offline with the founder).
set -euo pipefail
cd "$(dirname "$0")"
cert="$HOME/trubbo/backup-cert.pem"
case "${SSH_ORIGINAL_COMMAND:-}" in
  dump)
    # pipefail: a failing pg_dump fails the command instead of shipping a
    # truncated-but-valid-looking ciphertext.
    docker compose exec -T postgres pg_dump -U postgres -d quiz_pack --format=custom --compress=9 \
      | openssl cms -encrypt -binary -stream -aes256 -outform DER -recip "$cert"
    ;;
  df) df --output=pcent / | tail -1 ;;
  *) echo "allowed commands: dump | df" >&2; exit 2 ;;
esac
