#!/usr/bin/env bash
# Install the RS-01 pre-push smoke gate into .git/hooks/pre-push.
#
# Opt-in: this script is NOT run automatically. Run it once per clone if you
# want the smoke gate active. Bypass per-push with: git push --no-verify
#
# Uninstall: rm .git/hooks/pre-push
#
# The hook source lives at scripts/pre-push-rs01-smoke.sh and is the source of
# truth — this installer copies it into .git/hooks/pre-push so git can find it.
# Re-run this script after editing the source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$SCRIPT_DIR/pre-push-rs01-smoke.sh"
TARGET="$REPO_ROOT/.git/hooks/pre-push"

if [ ! -d "$REPO_ROOT/.git" ]; then
    echo "error: $REPO_ROOT is not a git repository" >&2
    exit 1
fi

if [ ! -f "$SOURCE" ]; then
    echo "error: hook source missing at $SOURCE" >&2
    exit 1
fi

if [ -e "$TARGET" ] && ! cmp -s "$SOURCE" "$TARGET"; then
    backup="$TARGET.backup.$(date +%Y%m%d%H%M%S)"
    echo "Existing pre-push hook found at $TARGET — backing up to $backup"
    mv "$TARGET" "$backup"
fi

cp "$SOURCE" "$TARGET"
chmod +x "$TARGET"

echo "Installed RS-01 pre-push smoke gate."
echo "  Source:  $SOURCE"
echo "  Hook:    $TARGET"
echo "  Bypass:  git push --no-verify"
echo "  Remove:  rm $TARGET"
