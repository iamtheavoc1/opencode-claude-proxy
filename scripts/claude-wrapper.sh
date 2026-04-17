#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="${OPENCODE_ANTHROPIC_AUTH_DIR:-$HOME/.local/share/opencode-anthropic-auth}"
DOCTOR="$PLUGIN_DIR/doctor.mjs"
PULL="$PLUGIN_DIR/pull-from-vps.sh"
RECOVER="$PLUGIN_DIR/recover.sh"
RESET="$PLUGIN_DIR/reset.sh"

find_real_claude() {
  if [[ -n "${CLAUDE_REAL_BIN:-}" && -x "$CLAUDE_REAL_BIN" ]]; then
    printf '%s\n' "$CLAUDE_REAL_BIN"
    return 0
  fi
  if [[ -x "$HOME/.local/bin/claude-real" ]]; then
    printf '%s\n' "$HOME/.local/bin/claude-real"
    return 0
  fi

  local self
  if command -v readlink >/dev/null 2>&1; then
    self=$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || printf '%s\n' "$0")
  else
    self="$0"
  fi

  local IFS=:
  local dir cand real
  for dir in $PATH; do
    [[ -z "$dir" ]] && continue
    cand="$dir/claude"
    [[ -x "$cand" ]] || continue
    real=$(readlink -f "$cand" 2>/dev/null || readlink "$cand" 2>/dev/null || printf '%s\n' "$cand")
    [[ "$real" == "$self" ]] && continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

REAL_CLAUDE=$(find_real_claude || true)
if [[ -z "$REAL_CLAUDE" ]]; then
  echo "opencode-anthropic-auth: could not locate the real 'claude' binary." >&2
  echo "Install Claude Code from https://claude.com/claude-code, or set" >&2
  echo "CLAUDE_REAL_BIN to the absolute path of the real binary." >&2
  exit 127
fi

case "${1:-}" in
  auth|setup-token|mcp)
    exec "$REAL_CLAUDE" "$@"
    ;;
esac

NODE_BIN="${OCAUTH_NODE:-$(command -v node 2>/dev/null || true)}"
[[ -z "$NODE_BIN" && -x /opt/homebrew/bin/node ]] && NODE_BIN=/opt/homebrew/bin/node
[[ -z "$NODE_BIN" && -x /usr/local/bin/node    ]] && NODE_BIN=/usr/local/bin/node

if [[ -z "$NODE_BIN" || ! -r "$DOCTOR" ]]; then
  echo "opencode-anthropic-auth: node or doctor.mjs missing; aborting." >&2
  echo "Re-run fix-opencode.sh to restore the auth helpers." >&2
  exit 2
fi

get_env_exports() {
  NODE_NO_WARNINGS=1 "$NODE_BIN" "$DOCTOR" env 2>/dev/null || true
}

NODE_NO_WARNINGS=1 "$NODE_BIN" "$DOCTOR" doctor --fix >/dev/null 2>&1 || true
ENV_EXPORTS=$(get_env_exports)

if [[ -z "$ENV_EXPORTS" && -x "$PULL" ]]; then
  "$PULL" >/dev/null 2>&1 || true
  NODE_NO_WARNINGS=1 "$NODE_BIN" "$DOCTOR" refresh --force >/dev/null 2>&1 || true
  ENV_EXPORTS=$(get_env_exports)
fi

if [[ -z "$ENV_EXPORTS" ]]; then
  echo >&2
  echo "+------------------------------------------------------+" >&2
  echo "|  opencode-anthropic-auth: no healthy auth env         |" >&2
  echo "|   1) Diagnose : node $DOCTOR status                   |" >&2
  echo "|   2) Recover  : $RECOVER                              |" >&2
  echo "|   3) Reset    : $RESET --yes                          |" >&2
  echo "+------------------------------------------------------+" >&2
  exit 2
fi

OUT=$(mktemp -t oaa.wrap.XXXXXX)
# shellcheck disable=SC2329  # cleanup is invoked via trap below
cleanup() { rm -f "$OUT"; }
trap cleanup EXIT

run_claude() {
  ( eval "$ENV_EXPORTS"; exec "$REAL_CLAUDE" "$@" ) \
    > >(tee -a "$OUT") 2> >(tee -a "$OUT" >&2)
}

run_claude "$@"
RC=$?
sleep 0.1

if [[ $RC -ne 0 ]] && grep -qE '(401|OAuth token|authentication_error|invalid_grant|refresh_token|invalid authentication credentials)' "$OUT" 2>/dev/null; then
  [[ -x "$PULL" ]] && "$PULL" >/dev/null 2>&1 || true
  NODE_NO_WARNINGS=1 "$NODE_BIN" "$DOCTOR" refresh --force >/dev/null 2>&1 || true
  ENV_EXPORTS=$(get_env_exports)
  if [[ -n "$ENV_EXPORTS" ]]; then
    : > "$OUT"
    run_claude "$@"
    RC=$?
    sleep 0.1
  fi
  if [[ $RC -ne 0 ]]; then
    echo >&2
    echo "+------------------------------------------------------+" >&2
    echo "|  opencode-anthropic-auth: token appears dead          |" >&2
    echo "|   1) Diagnose : node $DOCTOR status                   |" >&2
    echo "|   2) Recover  : $RECOVER                              |" >&2
    echo "|   3) Reset    : $RESET --yes                          |" >&2
    echo "+------------------------------------------------------+" >&2
  fi
fi

exit $RC
