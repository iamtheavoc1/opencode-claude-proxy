#!/usr/bin/env bash
# opencode-claude-proxy — manual keepalive (refreshes Claude OAuth)
#
# The systemd timer on the VPS calls this every 12h. You can also run it
# by hand to verify the token chain is healthy.
#
# Usage:
#   ./keepalive.sh                        # uses MERIDIAN_PORT=3456
#   MERIDIAN_PORT=3456 ./keepalive.sh

set -euo pipefail
PORT="${MERIDIAN_PORT:-3456}"
HOST="${MERIDIAN_HOST:-127.0.0.1}"

resp=$(curl -fsS -m 30 -X POST "http://${HOST}:${PORT}/v1/messages" \
  -H "content-type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -H "x-api-key: x" \
  -d '{"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"ok"}]}' \
  2>&1) || { echo "keepalive FAILED: $resp" >&2; exit 1; }

echo "$resp" | head -c 200
echo
