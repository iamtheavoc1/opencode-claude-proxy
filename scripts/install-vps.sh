#!/usr/bin/env bash
# opencode-claude-proxy — VPS installer
#
# Two modes:
#   --host <ssh-target>     SSH from your laptop to the VPS and install there
#   --local                 You're already on the VPS; install locally
#
# Optional:
#   --bind 0.0.0.0          Bind meridian publicly (NOT recommended; requires --i-know)
#   --bind tailscale        Bind meridian to the tailnet IP only (auto-detected)
#   --bind 127.0.0.1        (default) Loopback only — use SSH tunnel from your laptop
#   --port 3456             Override meridian port
#   --i-know                Acknowledge the public-bind warning
#   --skip-keepalive        Don't install the OAuth keepalive timer

set -euo pipefail

MODE=""
SSH_TARGET=""
BIND="127.0.0.1"
PORT="${MERIDIAN_PORT:-3456}"
ACK_PUBLIC=0
SKIP_KEEPALIVE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --host)            MODE=remote; SSH_TARGET="$2"; shift 2 ;;
    --local)           MODE=local; shift ;;
    --bind)            BIND="$2"; shift 2 ;;
    --port)            PORT="$2"; shift 2 ;;
    --i-know)          ACK_PUBLIC=1; shift ;;
    --skip-keepalive)  SKIP_KEEPALIVE=1; shift ;;
    -h|--help)
      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[ -n "$MODE" ] || { echo "must pass --host <ssh-target> or --local" >&2; exit 1; }

# ─── Remote bootstrap path ──────────────────────────────────────────────────
if [ "$MODE" = "remote" ]; then
  echo "==> Bootstrapping VPS via SSH ($SSH_TARGET)"
  REMOTE_SCRIPT_URL="https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/scripts/install-vps.sh"
  REMOTE_ARGS=( --local --bind "$BIND" --port "$PORT" )
  [ "$ACK_PUBLIC" = 1 ] && REMOTE_ARGS+=( --i-know )
  [ "$SKIP_KEEPALIVE" = 1 ] && REMOTE_ARGS+=( --skip-keepalive )
  ssh -t "$SSH_TARGET" "curl -fsSL $REMOTE_SCRIPT_URL | bash -s -- ${REMOTE_ARGS[*]}"
  exit $?
fi

# ─── Local install (running on the VPS) ─────────────────────────────────────

c_green()  { printf '\033[32m%s\033[0m' "$1"; }
c_red()    { printf '\033[31m%s\033[0m' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m' "$1"; }
c_cyan()   { printf '\033[36m%s\033[0m' "$1"; }
c_dim()    { printf '\033[2m%s\033[0m'  "$1"; }
step() { printf '\n%s %s\n' "$(c_cyan '==>')" "$1"; }
ok()   { printf '    %s %s\n' "$(c_green '✓')"  "$1"; }
warn() { printf '    %s %s\n' "$(c_yellow '!')" "$1"; }
fail() { printf '    %s %s\n' "$(c_red '✗')"    "$1"; exit 1; }
note() { printf '      %s\n'    "$(c_dim "$1")"; }

[ "$EUID" -eq 0 ] || fail "run as root (sudo bash) — needs to install systemd units and create the meridian user"

# ─── 1. Detect distro ────────────────────────────────────────────────────────
step "Detecting distro"
if [ -f /etc/os-release ]; then
  . /etc/os-release
  DISTRO="${ID:-unknown}"
else
  fail "/etc/os-release missing — unsupported distro"
fi
ok "distro: $DISTRO"

# ─── 2. Install Node 20 if missing ──────────────────────────────────────────
step "Ensuring Node ≥ 20"
NODE_VER=$(node --version 2>/dev/null | sed 's/^v//' || echo "")
NODE_MAJOR=${NODE_VER%%.*}
if [ -z "$NODE_VER" ] || [ "${NODE_MAJOR:-0}" -lt 20 ]; then
  case "$DISTRO" in
    debian|ubuntu)
      curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
      apt-get install -y nodejs
      ;;
    fedora|rhel|centos|rocky|almalinux)
      curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
      dnf install -y nodejs
      ;;
    arch|manjaro)
      pacman -Sy --noconfirm nodejs npm
      ;;
    alpine)
      apk add --no-cache nodejs npm
      ;;
    *)
      fail "unsupported distro: $DISTRO — install Node ≥ 20 manually then re-run"
      ;;
  esac
  ok "installed node $(node --version)"
else
  ok "node $(node --version)"
fi

# ─── 3. Install meridian ─────────────────────────────────────────────────────
step "Installing @rynfar/meridian"
npm install -g @rynfar/meridian --ignore-scripts
NPM_PREFIX=$(npm prefix -g)
MERIDIAN_PKG="$NPM_PREFIX/lib/node_modules/@rynfar/meridian"
[ -d "$MERIDIAN_PKG" ] || fail "meridian not at $MERIDIAN_PKG after install"
INSTALL_CJS="$MERIDIAN_PKG/node_modules/@anthropic-ai/claude-code/install.cjs"
[ -f "$INSTALL_CJS" ] && ( cd "$(dirname "$INSTALL_CJS")" && node install.cjs >/dev/null 2>&1 ) || true
MERIDIAN_BIN="$NPM_PREFIX/bin/meridian"
NODE_BIN=$(command -v node)
ok "meridian → $MERIDIAN_BIN"

# ─── 4. Force 200k via plugin patch ─────────────────────────────────────────
PLUGIN_TS="$MERIDIAN_PKG/plugin/meridian.ts"
if [ -f "$PLUGIN_TS" ] && ! grep -q '"x-opencode-agent-mode"\] = "subagent"' "$PLUGIN_TS"; then
  cp "$PLUGIN_TS" "$PLUGIN_TS.bak.before-200k"
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    let s = fs.readFileSync(p, "utf8");
    s = s.replace(
      /(output\.headers\["x-opencode-agent-mode"\]\s*=\s*[^;\n]+;?)/,
      "// FORCED 200k by opencode-claude-proxy installer\n      output.headers[\"x-opencode-agent-mode\"] = \"subagent\";\n      // $1"
    );
    fs.writeFileSync(p, s);
  ' "$PLUGIN_TS"
  ok "forced 200k context (subagent mode)"
fi

# ─── 5. Create meridian system user + state dirs ────────────────────────────
step "Creating meridian user and directories"
if ! id -u meridian >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/meridian --shell /usr/sbin/nologin meridian
fi
mkdir -p /var/lib/meridian/.claude /var/log/meridian /var/lib/meridian/.config/meridian /var/lib/meridian/.cache/meridian
chown -R meridian:meridian /var/lib/meridian /var/log/meridian
ok "meridian user → uid=$(id -u meridian) home=/var/lib/meridian"

# ─── 6. Resolve bind address ─────────────────────────────────────────────────
step "Resolving bind address"
case "$BIND" in
  tailscale)
    if ! command -v tailscale >/dev/null 2>&1; then
      fail "--bind tailscale requested but tailscale not installed; install via: curl -fsSL https://tailscale.com/install.sh | sh"
    fi
    BIND_IP=$(tailscale ip -4 | head -1 || true)
    [ -n "$BIND_IP" ] || fail "tailscale not connected; run: tailscale up"
    ok "binding to tailscale IP $BIND_IP"
    BIND="$BIND_IP"
    ;;
  0.0.0.0|"*")
    [ "$ACK_PUBLIC" = 1 ] || fail "refusing to bind publicly without --i-know — meridian has NO authentication layer"
    warn "binding meridian to 0.0.0.0 — make sure your firewall blocks port $PORT or you're behind a reverse proxy with auth"
    ;;
  127.0.0.1|localhost)
    ok "binding to loopback only (use SSH tunnel from your laptop)"
    ;;
  *)
    ok "binding to $BIND"
    ;;
esac

# ─── 7. Install meridian.service ────────────────────────────────────────────
step "Installing /etc/systemd/system/meridian.service"
cat > /etc/systemd/system/meridian.service <<EOF
[Unit]
Description=Meridian Anthropic proxy (opencode-claude-proxy)
Documentation=https://github.com/iamtheavoc1/opencode-claude-proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=meridian
Group=meridian
WorkingDirectory=/var/lib/meridian
Environment=HOME=/var/lib/meridian
Environment=MERIDIAN_PASSTHROUGH=1
Environment=MERIDIAN_PORT=$PORT
Environment=MERIDIAN_HOST=$BIND
Environment=MERIDIAN_OPUS_MODEL=opus
Environment=MERIDIAN_SONNET_MODEL=sonnet
Environment=PATH=$NPM_PREFIX/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$NODE_BIN $MERIDIAN_BIN
Restart=always
RestartSec=5
StandardOutput=append:/var/log/meridian/meridian.log
StandardError=append:/var/log/meridian/meridian.log

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=read-only
ReadWritePaths=/var/lib/meridian /var/log/meridian
ProtectSystem=strict
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
ok "meridian.service installed"

# ─── 8. Install keepalive service + timer ───────────────────────────────────
if [ "$SKIP_KEEPALIVE" = "0" ]; then
  step "Installing keepalive timer (12h OAuth refresh ping)"
  cat > /etc/systemd/system/meridian-keepalive.service <<EOF
[Unit]
Description=Meridian OAuth keepalive — issues a 1-token request to refresh the Anthropic OAuth token
Requires=meridian.service
After=meridian.service

[Service]
Type=oneshot
User=meridian
Group=meridian
ExecStart=/usr/bin/env bash -c '/usr/bin/curl -fsS -m 30 -X POST "http://127.0.0.1:$PORT/v1/messages" -H "content-type: application/json" -H "anthropic-version: 2023-06-01" -H "x-api-key: x" -d "{\"model\":\"claude-haiku-4-5\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}]}" >/dev/null'
EOF
  cat > /etc/systemd/system/meridian-keepalive.timer <<EOF
[Unit]
Description=Run meridian-keepalive every 12h to refresh OAuth

[Timer]
OnBootSec=15min
OnUnitActiveSec=12h
Unit=meridian-keepalive.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now meridian-keepalive.timer
  ok "keepalive timer enabled"
fi

# ─── 9. Auth bootstrap ──────────────────────────────────────────────────────
step "Bootstrapping Claude OAuth"
if sudo -u meridian -H bash -lc 'claude /status 2>/dev/null | grep -qi "logged in"'; then
  ok "claude OAuth already configured for meridian user"
else
  warn "claude OAuth not yet configured for the meridian user"
  cat <<EOF

  Pick one of the following paths to bring up OAuth on this VPS:

  ┌─ Path A: Run \`claude login\` on the VPS via SSH browser-port-forward
  │
  │  From your laptop, in a fresh terminal:
  │     ssh -L 1456:127.0.0.1:1456 $(hostname)
  │  Then on the VPS:
  │     sudo -u meridian -H bash
  │     export PATH=$NPM_PREFIX/bin:\$PATH
  │     claude login
  │  Open the localhost URL it prints — it will tunnel through your SSH
  │  session to your laptop browser.
  │
  ├─ Path B: Copy OAuth from your laptop
  │
  │  On your laptop (macOS):
  │     security find-generic-password -s 'Claude Code-credentials' -a "\$USER" -w \\
  │       > /tmp/claude-oauth.json
  │     scp /tmp/claude-oauth.json $(hostname):/tmp/
  │     rm /tmp/claude-oauth.json
  │  On the VPS:
  │     sudo install -m 600 -o meridian -g meridian \\
  │       /tmp/claude-oauth.json /var/lib/meridian/.claude/.credentials.json
  │     rm /tmp/claude-oauth.json
  │
  └─ After either path, restart meridian:
        systemctl restart meridian
EOF
fi

# ─── 10. Enable + start meridian ─────────────────────────────────────────────
step "Enabling meridian.service"
systemctl enable --now meridian.service
sleep 2
if systemctl is-active --quiet meridian; then
  ok "meridian running"
else
  warn "meridian not running — check journalctl -u meridian"
fi

# ─── 11. Health check ────────────────────────────────────────────────────────
step "Verifying"
HEALTH=$(curl -fsS "http://127.0.0.1:$PORT/healthz" 2>/dev/null || true)
if [ -n "$HEALTH" ]; then
  echo "$HEALTH" | python3 -m json.tool 2>/dev/null || echo "$HEALTH"
else
  warn "no response from http://127.0.0.1:$PORT/healthz"
fi

step "Done"
echo
echo "  Meridian is live on $(hostname) — bind=$BIND port=$PORT"
echo
echo "  ── Connecting opencode on your laptop ──────────────────────────"
echo
case "$BIND" in
  127.0.0.1|localhost)
    echo "  SSH tunnel (run on laptop):"
    echo "      ssh -fN -L $PORT:127.0.0.1:$PORT $(hostname)"
    echo "  Then in opencode.json keep:"
    echo "      provider.anthropic.options.baseURL = http://127.0.0.1:$PORT"
    ;;
  *)
    echo "  In opencode.json set:"
    echo "      provider.anthropic.options.baseURL = http://$BIND:$PORT"
    ;;
esac
echo
echo "  Logs:           journalctl -u meridian -f"
echo "  Keepalive:      systemctl list-timers meridian-keepalive.timer"
echo "  Telemetry:      curl -s http://127.0.0.1:$PORT/telemetry  # browser-friendly"
