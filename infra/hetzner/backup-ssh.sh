#!/usr/bin/env bash
# Forced command for the nightly-backup SSH key on the Hetzner server
# (#222 — moving the backend to Hetzner). In ~/.ssh/authorized_keys:
#   command="/home/trubbo/trubbo/bin/backup-ssh.sh",restrict ssh-ed25519 AAAA… quiz-pack-db-backup
# The key can only produce an encrypted dump, report disk usage or start a
# PITR base backup to R2; it cannot open a shell, forward ports or read
# anything in plaintext.
# The recipient cert is public (private key stays offline with the founder).
set -euo pipefail
cd /home/trubbo/trubbo/repo/infra/hetzner
cert="$HOME/trubbo/backup-cert.pem"
case "${SSH_ORIGINAL_COMMAND:-}" in
  dump)
    # pipefail: a failing pg_dump fails the command instead of shipping a
    # truncated-but-valid-looking ciphertext.
    docker compose exec -T postgres pg_dump -U postgres -d quiz_pack --format=custom --compress=9 \
      | openssl cms -encrypt -binary -stream -aes256 -outform DER -recip "$cert"
    ;;
  df) df --output=pcent / | tail -1 ;;
  # PITR base backup to R2 (#222), then drop what the 7-day window no longer
  # needs. WAL segments ship continuously (postgres/wal-archive.sh).
  basebackup)
    docker compose exec -T -u postgres postgres sh -ec '
      barman-cloud-backup --gzip --endpoint-url "$WAL_S3_ENDPOINT" "$WAL_S3_ARCHIVE" "$WAL_SERVER_NAME"
      barman-cloud-backup-delete --endpoint-url "$WAL_S3_ENDPOINT" \
        --retention-policy "RECOVERY WINDOW OF 7 DAYS" "$WAL_S3_ARCHIVE" "$WAL_SERVER_NAME"
      echo "base backup done"'
    ;;
  *) echo "allowed commands: dump | df | basebackup" >&2; exit 2 ;;
esac
