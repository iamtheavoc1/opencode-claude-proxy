#!/usr/bin/env bash
# opencode-claude-proxy — local installer (macOS / Linux desktop)
#
# Wires opencode into a local meridian proxy that authenticates with your
# `claude login` OAuth token. See README.md for architecture.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/install.sh | bash
#
# Optional env vars (see README for full list):
#   OPENCODE_CONFIG                       opencode.json path
#   MERIDIAN_PORT                         meridian port (default 3456)
#   OPENCODE_CLAUDE_PROXY_USE_1M=1        opt into opus[1m] / sonnet[1m]
#   OPENCODE_CLAUDE_PROXY_NO_AUTOSTART=1  skip launchd / systemd setup
#   OPENCODE_CLAUDE_PROXY_THINKING=...    disabled | adaptive | enabled

set -euo pipefail

CONFIG_PATH="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
MERIDIAN_PORT="${MERIDIAN_PORT:-3456}"
USE_1M="${OPENCODE_CLAUDE_PROXY_USE_1M:-0}"
NO_AUTOSTART="${OPENCODE_CLAUDE_PROXY_NO_AUTOSTART:-0}"
THINKING_MODE="${OPENCODE_CLAUDE_PROXY_THINKING:-adaptive}"
TS=$(date +%s)

c_green()  { printf '\033[32m%s\033[0m' "$1"; }
c_red()    { printf '\033[31m%s\033[0m' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m' "$1"; }
c_cyan()   { printf '\033[36m%s\033[0m' "$1"; }
c_dim()    { printf '\033[2m%s\033[0m'  "$1"; }
step()  { printf '\n%s %s\n' "$(c_cyan '==>')" "$1"; }
ok()    { printf '    %s %s\n' "$(c_green '✓')"  "$1"; }
warn()  { printf '    %s %s\n' "$(c_yellow '!')" "$1"; }
fail()  { printf '    %s %s\n' "$(c_red '✗')"    "$1"; exit 1; }
note()  { printf '      %s\n'    "$(c_dim "$1")"; }

# ─── 1. Detect platform ──────────────────────────────────────────────────────
step "Detecting platform"
case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)  PLATFORM=linux ;;
  *) fail "unsupported platform: $(uname -s) — only macOS and Linux are supported" ;;
esac
ok "platform: $PLATFORM"

# ─── 2. Resolve required tools ───────────────────────────────────────────────
step "Checking requirements"
resolve_tool() {
  local tool="$1"; shift
  local found
  found=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$found" ] && [ -x "$found" ]; then printf '%s' "$found"; return 0; fi
  for c in "$@"; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done
  return 1
}

NODE_BIN=$(resolve_tool node /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node) \
  || fail "node not found — install Node.js ≥ 20 from https://nodejs.org or via your package manager"
NODE_VER=$("$NODE_BIN" --version | sed 's/^v//')
NODE_MAJOR=${NODE_VER%%.*}
[ "$NODE_MAJOR" -ge 20 ] || fail "node $NODE_VER is too old — need ≥ 20"
ok "node — v$NODE_VER"

NPM_BIN=$(resolve_tool npm /opt/homebrew/bin/npm /usr/local/bin/npm /usr/bin/npm) \
  || fail "npm not found"
ok "npm — $("$NPM_BIN" --version)"

OPENCODE_BIN=$(resolve_tool opencode "$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode) \
  || fail "opencode not found — install from https://opencode.ai"
ok "opencode — $("$OPENCODE_BIN" --version 2>/dev/null || echo unknown)"

CLAUDE_BIN=$(resolve_tool claude "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude) \
  || fail "claude CLI not found — install from https://docs.claude.com/en/docs/claude-code/overview"
ok "claude — $("$CLAUDE_BIN" --version 2>/dev/null || echo unknown)"

JQ_BIN=$(resolve_tool jq /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq) \
  || fail "jq not found — install via 'brew install jq' or 'apt install jq'"
ok "jq — $("$JQ_BIN" --version)"

# ─── 3. Install or update meridian ───────────────────────────────────────────
step "Installing @rynfar/meridian"
"$NPM_BIN" install -g @rynfar/meridian --ignore-scripts 2>&1 | sed 's/^/      /' || \
  fail "npm install failed"

NPM_PREFIX=$("$NPM_BIN" prefix -g)
MERIDIAN_PKG="$NPM_PREFIX/lib/node_modules/@rynfar/meridian"
[ -d "$MERIDIAN_PKG" ] || fail "meridian package not found at $MERIDIAN_PKG after install"
ok "meridian installed at $MERIDIAN_PKG"

# Manually run the postinstall to materialise the claude binary placeholder.
INSTALL_CJS="$MERIDIAN_PKG/node_modules/@anthropic-ai/claude-code/install.cjs"
if [ -f "$INSTALL_CJS" ]; then
  ( cd "$(dirname "$INSTALL_CJS")" && "$NODE_BIN" install.cjs >/dev/null 2>&1 ) || true
fi
CLAUDE_BIN_IN_PKG="$MERIDIAN_PKG/node_modules/@anthropic-ai/claude-code/bin/claude.exe"
if [ ! -s "$CLAUDE_BIN_IN_PKG" ]; then
  warn "claude binary placeholder not populated; meridian may fail with spawn ENOEXEC"
  note "manual fix: cd $MERIDIAN_PKG/node_modules/@anthropic-ai/claude-code && node install.cjs"
else
  ok "claude binary materialised ($(du -h "$CLAUDE_BIN_IN_PKG" | awk '{print $1}'))"
fi

MERIDIAN_BIN=$(resolve_tool meridian "$NPM_PREFIX/bin/meridian") \
  || fail "meridian binary not on PATH after install"

# ─── 4. Force 200k context (subagent mode) unless opted out ─────────────────
PLUGIN_TS="$MERIDIAN_PKG/plugin/meridian.ts"
if [ "$USE_1M" = "1" ]; then
  ok "leaving meridian plugin untouched (USE_1M=1; will use opus[1m] / sonnet[1m] when applicable)"
else
  step "Forcing 200k context (subagent agent mode)"
  if [ -f "$PLUGIN_TS" ]; then
    [ -f "$PLUGIN_TS.bak.before-200k" ] || cp "$PLUGIN_TS" "$PLUGIN_TS.bak.before-200k"
    if ! grep -q '"x-opencode-agent-mode"\] = "subagent"' "$PLUGIN_TS"; then
      "$NODE_BIN" -e '
        const fs = require("fs");
        const p = process.argv[1];
        let s = fs.readFileSync(p, "utf8");
        // Insert a hard-set just before the first existing assignment to x-opencode-agent-mode.
        s = s.replace(
          /(output\.headers\["x-opencode-agent-mode"\]\s*=\s*[^;\n]+;?)/,
          "// FORCED 200k by opencode-claude-proxy installer — comment out to restore meridian default routing\n      output.headers[\"x-opencode-agent-mode\"] = \"subagent\";\n      // $1"
        );
        fs.writeFileSync(p, s);
      ' "$PLUGIN_TS"
      ok "patched $PLUGIN_TS"
    else
      ok "plugin already patched"
    fi
  else
    warn "plugin file not found at $PLUGIN_TS — meridian may have changed layout; skipping 200k force"
  fi
fi

# ─── 5. Check claude OAuth ───────────────────────────────────────────────────
step "Checking claude OAuth"
if "$CLAUDE_BIN" /status 2>/dev/null | grep -qi 'logged in'; then
  ok "claude OAuth active"
elif "$CLAUDE_BIN" --print --max-turns 0 'noop' >/dev/null 2>&1; then
  ok "claude OAuth active (verified by noop)"
else
  warn "claude does not appear to be logged in"
  note "run: claude login"
  note "then re-run this installer or just start meridian — it will pick up auth on first request"
fi

# ─── 6. Configure meridian sdk-features ─────────────────────────────────────
step "Configuring meridian sdk-features"
SDKF_DIR="$HOME/.config/meridian"
mkdir -p "$SDKF_DIR"
SDKF_FILE="$SDKF_DIR/sdk-features.json"
case "$THINKING_MODE" in
  disabled|adaptive|enabled) ;;
  *) fail "OPENCODE_CLAUDE_PROXY_THINKING must be one of: disabled, adaptive, enabled (got: $THINKING_MODE)" ;;
esac
if [ -f "$SDKF_FILE" ]; then cp "$SDKF_FILE" "$SDKF_FILE.bak.before-meridian-$TS"; fi
"$JQ_BIN" -n \
  --arg thinking "$THINKING_MODE" \
  '{ opencode: { thinking: $thinking, thinkingPassthrough: true } }' \
  > "$SDKF_FILE"
ok "wrote $SDKF_FILE (thinking=$THINKING_MODE, passthrough=true)"

# ─── 7. Patch opencode.json ──────────────────────────────────────────────────
step "Patching $CONFIG_PATH"
mkdir -p "$(dirname "$CONFIG_PATH")"
[ -f "$CONFIG_PATH" ] || echo '{}' > "$CONFIG_PATH"
cp "$CONFIG_PATH" "$CONFIG_PATH.bak.before-meridian-$TS"
ok "backup → $CONFIG_PATH.bak.before-meridian-$TS"

PLUGIN_PATH="$PLUGIN_TS"
"$JQ_BIN" \
  --arg base "http://127.0.0.1:$MERIDIAN_PORT" \
  --arg plugin "$PLUGIN_PATH" \
  '
  # ensure provider.anthropic.options exists with our baseURL
  .provider                                   //= {} |
  .provider.anthropic                         //= {} |
  .provider.anthropic.options                 //= {} |
  .provider.anthropic.options.baseURL          = $base |
  .provider.anthropic.options.apiKey          //= "x" |
  # strip thinking overrides on every anthropic model so meridian adaptive wins
  ( .provider.anthropic.models // {} ) as $m |
  .provider.anthropic.models =
    ( $m | with_entries( .value |= ( del(.options.thinking) | if .options == {} then del(.options) else . end ) ) ) |
  # ensure plugin array contains the meridian plugin
  .plugin //= [] |
  .plugin = ( ( .plugin // [] ) + [$plugin] | unique )
  ' "$CONFIG_PATH.bak.before-meridian-$TS" > "$CONFIG_PATH.tmp"

mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
ok "patched provider.anthropic.options.baseURL = http://127.0.0.1:$MERIDIAN_PORT"
ok "stripped per-model thinking overrides"
ok "ensured meridian plugin in plugin[] array"

# ─── 8. Autostart (launchd / systemd --user) ────────────────────────────────
if [ "$NO_AUTOSTART" = "1" ]; then
  warn "skipping autostart (NO_AUTOSTART=1)"
else
  step "Setting up autostart"
  case "$PLATFORM" in
    macos)
      LA_DIR="$HOME/Library/LaunchAgents"
      mkdir -p "$LA_DIR"
      PLIST="$LA_DIR/dev.meridian.proxy.plist"
      mkdir -p "$HOME/.cache/meridian"
      cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>           <string>dev.meridian.proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>$NODE_BIN</string>
        <string>$MERIDIAN_BIN</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MERIDIAN_PASSTHROUGH</key> <string>1</string>
        <key>MERIDIAN_PORT</key>        <string>$MERIDIAN_PORT</string>
        <key>MERIDIAN_OPUS_MODEL</key>  <string>opus</string>
        <key>MERIDIAN_SONNET_MODEL</key><string>sonnet</string>
        <key>PATH</key>                 <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>      <true/>
    <key>KeepAlive</key>      <true/>
    <key>ThrottleInterval</key> <integer>10</integer>
    <key>WorkingDirectory</key> <string>$HOME</string>
    <key>StandardOutPath</key>  <string>$HOME/.cache/meridian/meridian.log</string>
    <key>StandardErrorPath</key><string>$HOME/.cache/meridian/meridian.log</string>
</dict>
</plist>
EOF
      plutil -lint "$PLIST" > /dev/null || fail "generated plist failed plutil lint"
      # Bootstrap, replacing any prior load.
      launchctl bootout "gui/$(id -u)/dev.meridian.proxy" 2>/dev/null || true
      launchctl bootstrap "gui/$(id -u)" "$PLIST"
      ok "launchd agent loaded — dev.meridian.proxy"
      note "logs: tail -f $HOME/.cache/meridian/meridian.log"
      ;;
    linux)
      UNIT_DIR="$HOME/.config/systemd/user"
      mkdir -p "$UNIT_DIR"
      cat > "$UNIT_DIR/meridian.service" <<EOF
[Unit]
Description=Meridian Anthropic proxy (opencode-claude-proxy)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$NODE_BIN $MERIDIAN_BIN
Environment=MERIDIAN_PASSTHROUGH=1
Environment=MERIDIAN_PORT=$MERIDIAN_PORT
Environment=MERIDIAN_OPUS_MODEL=opus
Environment=MERIDIAN_SONNET_MODEL=sonnet
Environment=PATH=/usr/local/bin:/usr/bin:/bin
WorkingDirectory=%h
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
      systemctl --user daemon-reload
      systemctl --user enable --now meridian.service
      loginctl enable-linger "$USER" 2>/dev/null || true
      ok "systemd --user unit enabled — meridian.service"
      note "logs: journalctl --user -u meridian -f"
      ;;
  esac
fi

# ─── 9. Health check ─────────────────────────────────────────────────────────
step "Verifying"
sleep 2
HEALTH=$(curl -fsS "http://127.0.0.1:$MERIDIAN_PORT/healthz" 2>/dev/null || true)
if [ -z "$HEALTH" ]; then
  warn "could not reach meridian on http://127.0.0.1:$MERIDIAN_PORT"
  note "if you skipped autostart, run: $MERIDIAN_BIN"
else
  LOGGED_IN=$(echo "$HEALTH" | "$JQ_BIN" -r '.auth.loggedIn // false')
  SUB=$(echo "$HEALTH" | "$JQ_BIN" -r '.auth.subscriptionType // "unknown"')
  EMAIL=$(echo "$HEALTH" | "$JQ_BIN" -r '.auth.email // "—"')
  if [ "$LOGGED_IN" = "true" ]; then
    ok "meridian healthy — $EMAIL ($SUB subscription)"
  else
    warn "meridian up but not authenticated"
    note "run: claude login"
  fi
fi

step "Done"
ok "Restart any opencode TUI sessions you have open so they pick up the new baseURL."
note "Logs:        tail -f ~/.cache/meridian/meridian.log    (macOS)"
note "             journalctl --user -u meridian -f          (Linux)"
note "Telemetry:   open http://127.0.0.1:$MERIDIAN_PORT/telemetry"
note "Uninstall:   curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/scripts/uninstall.sh | bash"
