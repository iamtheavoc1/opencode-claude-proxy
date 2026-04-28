#!/usr/bin/env bash
# opencode-claude-proxy — export local Claude OAuth for VPS bootstrapping
#
# On macOS the Claude OAuth lives in the login keychain. On Linux it lives
# in ~/.claude/.credentials.json. This script writes a portable JSON file
# you can scp to a VPS and drop into /var/lib/meridian/.claude/.credentials.json.
#
# Usage:
#   ./auth-export.sh                            # → /tmp/claude-oauth.json
#   OUT=./oauth.json ./auth-export.sh
#
# Then on the VPS:
#   sudo install -m 600 -o meridian -g meridian /tmp/claude-oauth.json \
#     /var/lib/meridian/.claude/.credentials.json
#   sudo systemctl restart meridian

set -euo pipefail
OUT="${OUT:-/tmp/claude-oauth.json}"

case "$(uname -s)" in
  Darwin)
    if security find-generic-password -s 'Claude Code-credentials' -a "$USER" -w 2>/dev/null > "$OUT"; then
      :
    else
      echo "Could not read 'Claude Code-credentials' from your login keychain." >&2
      echo "Run \`claude login\` first, or unlock the keychain in Keychain Access." >&2
      exit 1
    fi
    ;;
  Linux)
    SRC="$HOME/.claude/.credentials.json"
    [ -f "$SRC" ] || { echo "no credentials at $SRC — run claude login first" >&2; exit 1; }
    cp "$SRC" "$OUT"
    ;;
  *)
    echo "unsupported platform: $(uname -s)" >&2; exit 1 ;;
esac

chmod 600 "$OUT"
echo "wrote $OUT (mode 600)"
echo
echo "Next steps:"
echo "  scp \"$OUT\" your-vps:/tmp/"
echo "  ssh your-vps 'sudo install -m 600 -o meridian -g meridian /tmp/$(basename "$OUT") /var/lib/meridian/.claude/.credentials.json && sudo systemctl restart meridian && rm /tmp/$(basename "$OUT")'"
echo "  rm \"$OUT\""
