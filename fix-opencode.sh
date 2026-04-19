#!/usr/bin/env bash
# fix-opencode.sh — make OpenCode bill Anthropic calls against your Claude
# Pro/Max subscription instead of hitting "You're out of extra usage".
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-anthropic-auth-fix/main/fix-opencode.sh | bash
#
# Optional install mode override:
#   OCAUTH_INSTALL_MODE=manual         install helpers + wrapper only (no local daemon)
#   OCAUTH_INSTALL_MODE=recurring-local  install local recurring refresh automation
#
# What it does, in order:
#   1. Verifies requirements (claude CLI, opencode, npm/git)
#   2. Downloads @ex-machina/opencode-anthropic-auth from npm (the only plugin
#      that actually handles Anthropic's OAuth request-shape validation correctly)
#   3. Installs it to ~/.local/share/opencode-anthropic-auth
#   4. Patches the installed plugin so expired OAuth sessions self-heal:
#      - refreshes within 60s of expiry instead of waiting until fully expired
#      - if OpenCode's refresh token has gone stale but Claude CLI is still
#        logged in, borrows a fresh Claude CLI bearer token locally and keeps going
#   5. Updates ~/.config/opencode/opencode.json:
#      - removes any previously installed opencode-claude-bridge entry
#      - removes any previously installed claude-proxy provider entry
#      - adds the ex-machina plugin via file:// reference
#      - sets default model to anthropic/claude-sonnet-4-6 if none is set
#   6. Backs up your opencode.json before modifying
#   7. Optionally installs a proactive token refresh daemon (LaunchAgent on macOS,
#      cron on Linux) that refreshes tokens every 45 minutes so the OAuth
#      chain rarely breaks while the local machine is awake
#
# Why this is needed — the actual root cause:
#
#   Anthropic's /v1/messages API validates the `system[]` array for OAuth
#   requests. ONLY the Claude Code identity block is allowed in system[];
#   anything else (OpenCode's agent prompts, tool descriptions, Sisyphus
#   configuration, etc.) triggers a 400 that surfaces as
#   "You're out of extra usage". It's a misleading error — the pool isn't
#   the problem, it's the request shape.
#
#   The ex-machina plugin transparently relocates every non-identity
#   system block to the first user message, satisfying the validation.
#   opencode-claude-bridge does NOT do this, which is why it produces the
#   error on every turn that involves OMO, OpenCode's tool descriptions,
#   or any multi-block system prompt.
#
#   Verified end-to-end by running `opencode run` with Sisyphus
#   (OhMyOpenCode) agent — sonnet-4-6 returns HTTP 200 and the expected
#   response text.

set -euo pipefail

REPO_ENTRY_DIR="${OPENCODE_ANTHROPIC_AUTH_DIR:-$HOME/.local/share/opencode-anthropic-auth}"
CONFIG_PATH="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
PLUGIN_REF="file://$REPO_ENTRY_DIR/dist/index.js"
NPM_PKG="@ex-machina/opencode-anthropic-auth"

# ─── Mode detection ──────────────────────────────────────────────────────────
# VPS-offload mode: if $REPO_ENTRY_DIR/.vps-config exists (from install-vps-daemon.sh),
# the installer skips the local refresh daemon (no LaunchAgent/cron/caffeinate)
# and instead installs pull-from-vps.sh so the Mac pulls fresh tokens on demand
# from a Tailscale-networked VPS that handles refresh.
#
# Override: OCAUTH_FORCE_MAC_MODE=1 forces the legacy Mac-only path even when
# .vps-config is present (useful for testing or temporary rollback).
VPS_CONFIG="$REPO_ENTRY_DIR/.vps-config"
if [ -n "${OCAUTH_VPS_HOST:-}" ] && [ "${OCAUTH_FORCE_MAC_MODE:-}" != "1" ]; then
  MODE="vps-offload"
elif [ -f "$VPS_CONFIG" ] && [ "${OCAUTH_FORCE_MAC_MODE:-}" != "1" ]; then
  MODE="vps-offload"
else
  MODE="mac-only"
fi

INSTALL_MODE="${OCAUTH_INSTALL_MODE:-recurring-local}"
case "$INSTALL_MODE" in
  manual|recurring-local) ;;
  *) printf 'unsupported OCAUTH_INSTALL_MODE=%s (expected: manual or recurring-local)\n' "$INSTALL_MODE" >&2; exit 1 ;;
esac

c_green()  { printf '\033[32m%s\033[0m' "$1"; }
c_red()    { printf '\033[31m%s\033[0m' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m' "$1"; }
c_cyan()   { printf '\033[36m%s\033[0m' "$1"; }
c_dim()    { printf '\033[2m%s\033[0m'  "$1"; }

step() { printf '\n%s %s\n' "$(c_cyan '==>')" "$1"; }
ok()   { printf '    %s %s\n' "$(c_green '✓')"  "$1"; }
warn() { printf '    %s %s\n' "$(c_yellow '!')" "$1"; }
fail() { printf '    %s %s\n' "$(c_red '✗')"    "$1"; exit 1; }
note() { printf '      %s\n' "$(c_dim "$1")"; }

resolve_tool() {
  local tool="$1"; shift
  local found
  found=$(command -v "$tool" 2>/dev/null || true)
  if [ -n "$found" ] && [ -x "$found" ]; then printf '%s' "$found"; return 0; fi
  for c in "$@"; do [ -x "$c" ] && { printf '%s' "$c"; return 0; }; done
  return 1
}

# ─── Requirements ────────────────────────────────────────────────────────────
step "Checking requirements"

GIT_BIN=$(resolve_tool git /opt/homebrew/bin/git /usr/local/bin/git /usr/bin/git) \
  || fail "git not found — install from https://git-scm.com/downloads"
ok "git — $("$GIT_BIN" --version | awk '{print $3}')"

CLAUDE_BIN=$(resolve_tool claude "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude) \
  || fail "claude CLI not found — https://docs.claude.com/en/docs/claude-code/overview, then run 'claude login'"
ok "claude CLI — $("$CLAUDE_BIN" --version 2>/dev/null || echo unknown)"
note "binary: $CLAUDE_BIN"

NPM_BIN=$(resolve_tool npm /opt/homebrew/bin/npm /usr/local/bin/npm) \
  || fail "npm not found — required to download the plugin from the npm registry"
ok "npm — $("$NPM_BIN" --version)"

NODE_BIN=$(resolve_tool node /opt/homebrew/bin/node /usr/local/bin/node) \
  || true
if [ -n "${NODE_BIN:-}" ]; then
  ok "node — $("$NODE_BIN" --version 2>/dev/null)"
else
  warn "node not found — proactive token refresh won't be installed"
  note "Plugin still works but tokens won't auto-refresh while idle"
fi

OPENCODE_BIN=$(resolve_tool opencode "$HOME/.opencode/bin/opencode" /opt/homebrew/bin/opencode /usr/local/bin/opencode) \
  || warn "opencode binary not found on PATH — installer will still work, but you'll need to install OpenCode before it takes effect"
[ -n "${OPENCODE_BIN:-}" ] && ok "opencode — $("$OPENCODE_BIN" --version 2>/dev/null | head -1)"

PY_BIN=$(resolve_tool python3 /opt/homebrew/bin/python3 /usr/bin/python3 /usr/local/bin/python3) \
  || fail "python3 not found — required to patch the plugin and safely update opencode.json"
ok "python3 — $("$PY_BIN" --version 2>/dev/null | awk '{print $2}')"

# ─── Download + install the plugin ───────────────────────────────────────────
step "Installing $NPM_PKG to $REPO_ENTRY_DIR"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TMP_VPS_CONFIG=""
if [ -f "$VPS_CONFIG" ]; then
  TMP_VPS_CONFIG="$TMPDIR/.vps-config.preserve"
  cp "$VPS_CONFIG" "$TMP_VPS_CONFIG"
fi
(
  cd "$TMPDIR"
  "$NPM_BIN" pack "$NPM_PKG" --silent 2>/dev/null || fail "failed to download $NPM_PKG from npm"
) || exit 1

TARBALL=$(ls "$TMPDIR"/*.tgz 2>/dev/null | head -1)
[ -n "$TARBALL" ] || fail "npm pack produced no tarball"

tar -xzf "$TARBALL" -C "$TMPDIR" || fail "failed to extract $TARBALL"

mkdir -p "$(dirname "$REPO_ENTRY_DIR")"
rm -rf "$REPO_ENTRY_DIR"
mv "$TMPDIR/package" "$REPO_ENTRY_DIR"
[ -n "$TMP_VPS_CONFIG" ] && cp "$TMP_VPS_CONFIG" "$VPS_CONFIG"

[ -f "$REPO_ENTRY_DIR/dist/index.js" ] || fail "extracted plugin is missing dist/index.js"
ok "installed to $REPO_ENTRY_DIR"
ok "entry: $PLUGIN_REF"

# ─── Patch plugin auth recovery ──────────────────────────────────────────────
step "Patching plugin auth recovery"

cat > "$REPO_ENTRY_DIR/dist/claude-cli-sync.js" <<'JS'
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
const SYNC_PROMPT = 'say exactly: AUTH_SYNC_OK';
const SYNC_MODEL = process.env.OPENCODE_ANTHROPIC_AUTH_CLAUDE_SYNC_MODEL || 'claude-sonnet-4-6';
const SYNC_TIMEOUT_MS = Number(process.env.OPENCODE_ANTHROPIC_AUTH_CLAUDE_SYNC_TIMEOUT_MS || 20000);
const SYNC_TTL_MS = Number(process.env.OPENCODE_ANTHROPIC_AUTH_CLAUDE_SYNC_TTL_MS || 1800000);
function resolveClaudeBin() {
    const candidates = [
        process.env.CLAUDE_BIN,
        join(homedir(), '.local/bin/claude'),
        join(homedir(), '.claude/local/claude'),
        '/opt/homebrew/bin/claude',
        '/usr/local/bin/claude',
        'claude',
    ].filter(Boolean);
    for (const candidate of candidates) {
        if (candidate === 'claude' || existsSync(candidate))
            return candidate;
    }
    return 'claude';
}
function captureClaudeCliBearer() {
    return new Promise((resolve, reject) => {
        let child = null;
        let settled = false;
        let timeout = null;
        let stderr = '';
        const finish = (handler, value) => {
            if (settled)
                return;
            settled = true;
            if (timeout)
                clearTimeout(timeout);
            server.close();
            if (child && child.exitCode === null) {
                child.kill('SIGTERM');
            }
            handler(value);
        };
        const server = createServer((req, res) => {
            if (req.method === 'HEAD') {
                res.writeHead(200);
                res.end();
                return;
            }
            if (req.method === 'POST' && req.url?.startsWith('/v1/messages')) {
                const authorization = req.headers.authorization;
                res.writeHead(204);
                res.end();
                if (typeof authorization === 'string' && authorization.startsWith('Bearer ')) {
                    finish(resolve, authorization.slice('Bearer '.length));
                    return;
                }
                finish(reject, new Error('Claude CLI token sync captured no bearer token'));
                return;
            }
            res.writeHead(404);
            res.end();
        });
        server.on('error', (error) => finish(reject, error));
        server.listen(0, '127.0.0.1', () => {
            const address = server.address();
            if (!address || typeof address === 'string') {
                finish(reject, new Error('Claude CLI token sync failed to bind loopback server'));
                return;
            }
            const env = {
                ...process.env,
                ANTHROPIC_BASE_URL: `http://127.0.0.1:${address.port}`,
            };
            child = spawn(resolveClaudeBin(), ['--print', SYNC_PROMPT, '--model', SYNC_MODEL], {
                cwd: homedir(),
                env,
                stdio: ['ignore', 'ignore', 'pipe'],
            });
            child.stderr.on('data', (chunk) => {
                stderr += chunk.toString();
                if (stderr.length > 2000) {
                    stderr = stderr.slice(-2000);
                }
            });
            child.on('error', (error) => finish(reject, error));
            child.on('exit', (code) => {
                if (!settled) {
                    const suffix = stderr.trim() ? ` — ${stderr.trim()}` : '';
                    finish(reject, new Error(`Claude CLI exited before token sync completed (${code ?? 'unknown'})${suffix}`));
                }
            });
        });
        timeout = setTimeout(() => {
            finish(reject, new Error('Timed out syncing token from Claude CLI'));
        }, SYNC_TIMEOUT_MS);
    });
}
export async function syncClaudeCliAccessToken() {
    const access = await captureClaudeCliBearer();
    return {
        access,
        expires: Date.now() + Math.max(60000, SYNC_TTL_MS),
    };
}
JS

REPO_ENTRY_DIR="$REPO_ENTRY_DIR" "$PY_BIN" - <<'PY' || fail "failed to patch plugin auth recovery"
from pathlib import Path
import os, sys

index_path = Path(os.environ["REPO_ENTRY_DIR"]) / "dist" / "index.js"
src = index_path.read_text()

transform_import_candidates = [
    "import { createStrippedStream, isInsecure, mergeHeaders, rewriteRequestBody, rewriteUrl, setOAuthHeaders, } from './transform';\n",
    "import { createStrippedStream, isInsecure, mergeHeaders, rewriteRequestBody, rewriteUrl, setOAuthHeaders, } from './transform.js';\n",
    'import { createStrippedStream, isInsecure, mergeHeaders, rewriteRequestBody, rewriteUrl, setOAuthHeaders, } from "./transform";\n',
    'import { createStrippedStream, isInsecure, mergeHeaders, rewriteRequestBody, rewriteUrl, setOAuthHeaders, } from "./transform.js";\n',
]
if "syncClaudeCliAccessToken" not in src:
    import_line = next((line for line in transform_import_candidates if line in src), None)
    if import_line is None:
        print("    unsupported upstream index.js layout (import line not found)", file=sys.stderr)
        sys.exit(1)
    quote = '"' if 'from "' in import_line else "'"
    suffix = '.js' if 'transform.js' in import_line else ''
    sync_import_line = f"import {{ syncClaudeCliAccessToken }} from {quote}./claude-cli-sync{suffix}{quote};\n"
    src = src.replace(import_line, import_line + sync_import_line, 1)

marker = "                    let refreshPromise = null;\n"
helper = """                    let refreshPromise = null;\n                    let cliSyncPromise = null;\n                    const syncFromClaudeCli = async () => {\n                        if (!cliSyncPromise) {\n                            cliSyncPromise = (async () => {\n                                const synced = await syncClaudeCliAccessToken();\n                                const existing = await getAuth();\n                                const preservedRefresh = existing.type === 'oauth' ? existing.refresh : undefined;\n                                await client.auth.set({\n                                    path: {\n                                        id: 'anthropic',\n                                    },\n                                    body: {\n                                        type: 'oauth',\n                                        refresh: preservedRefresh,\n                                        access: synced.access,\n                                        expires: synced.expires,\n                                    },\n                                });\n                                return synced.access;\n                            })().finally(() => {\n                                cliSyncPromise = null;\n                            });\n                        }\n                        return await cliSyncPromise;\n                    };\n                    const refreshOrSync = async () => {\n                        const latest = await getAuth();\n                        if (latest.type !== 'oauth' || !latest.refresh) {\n                            return await syncFromClaudeCli();\n                        }\n                        if (!refreshPromise) {\n                            refreshPromise = (async () => {\n                                const maxRetries = 2;\n                                const baseDelayMs = 500;\n                                for (let attempt = 0; attempt <= maxRetries; attempt++) {\n                                    try {\n                                        if (attempt > 0) {\n                                            const delay = baseDelayMs * 2 ** (attempt - 1);\n                                            await new Promise((resolve) => setTimeout(resolve, delay));\n                                        }\n                                        const response = await fetch(TOKEN_URL, {\n                                            method: 'POST',\n                                            headers: {\n                                                'Content-Type': 'application/json',\n                                                Accept: 'application/json, text/plain, */*',\n                                                'User-Agent': 'axios/1.13.6',\n                                            },\n                                            body: JSON.stringify({\n                                                grant_type: 'refresh_token',\n                                                refresh_token: latest.refresh,\n                                                client_id: CLIENT_ID,\n                                            }),\n                                        });\n                                        if (!response.ok) {\n                                            if (response.status >= 500 && attempt < maxRetries) {\n                                                await response.body?.cancel();\n                                                continue;\n                                            }\n                                            const body = await response.text().catch(() => '');\n                                            const isInvalidGrant = response.status == 400 && body.includes('invalid_grant');\n                                            if (isInvalidGrant) {\n                                                return await syncFromClaudeCli();\n                                            }\n                                            throw new Error(`Token refresh failed: ${response.status} — ${body}`);\n                                        }\n                                        const json = (await response.json());\n                                        await client.auth.set({\n                                            path: {\n                                                id: 'anthropic',\n                                            },\n                                            body: {\n                                                type: 'oauth',\n                                                refresh: json.refresh_token,\n                                                access: json.access_token,\n                                                expires: Date.now() + json.expires_in * 1000,\n                                            },\n                                        });\n                                        return json.access_token;\n                                    }\n                                    catch (error) {\n                                        const isNetworkError = error instanceof Error &&\n                                            (error.message.includes('fetch failed') ||\n                                                ('code' in error &&\n                                                    (error.code === 'ECONNRESET' ||\n                                                        error.code === 'ECONNREFUSED' ||\n                                                        error.code === 'ETIMEDOUT' ||\n                                                        error.code === 'UND_ERR_CONNECT_TIMEOUT')));\n                                        if (attempt < maxRetries && isNetworkError) {\n                                            continue;\n                                        }\n                                        throw error;\n                                    }\n                                }\n                                throw new Error('Token refresh exhausted all retries');\n                            })().finally(() => {\n                                refreshPromise = null;\n                            });\n                        }\n                        return await refreshPromise;\n                    };\n"""
if "const syncFromClaudeCli = async () => {" not in src:
    if marker not in src:
        print("    unsupported upstream index.js layout (refresh marker not found)", file=sys.stderr)
        sys.exit(1)
    src = src.replace(marker, helper, 1)

old_if = """                            if (!auth.access || !auth.expires || auth.expires < Date.now()) {\n                                if (!refreshPromise) {\n                                    refreshPromise = (async () => {\n                                        const maxRetries = 2;\n                                        const baseDelayMs = 500;\n                                        for (let attempt = 0; attempt <= maxRetries; attempt++) {\n                                            try {\n                                                if (attempt > 0) {\n                                                    const delay = baseDelayMs * 2 ** (attempt - 1);\n                                                    await new Promise((resolve) => setTimeout(resolve, delay));\n                                                }\n                                                const response = await fetch(TOKEN_URL, {\n                                                    method: 'POST',\n                                                    headers: {\n                                                        'Content-Type': 'application/json',\n                                                        Accept: 'application/json, text/plain, */*',\n                                                        'User-Agent': 'axios/1.13.6',\n                                                    },\n                                                    body: JSON.stringify({\n                                                        grant_type: 'refresh_token',\n                                                        refresh_token: auth.refresh,\n                                                        client_id: CLIENT_ID,\n                                                    }),\n                                                });\n                                                if (!response.ok) {\n                                                    if (response.status >= 500 && attempt < maxRetries) {\n                                                        await response.body?.cancel();\n                                                        continue;\n                                                    }\n                                                    const body = await response.text().catch(() => '');\n                                                    throw new Error(`Token refresh failed: ${response.status} — ${body}`);\n                                                }\n                                                const json = (await response.json());\n                                                // biome-ignore lint/suspicious/noExplicitAny: SDK types don't expose auth.set\n                                                await client.auth.set({\n                                                    path: {\n                                                        id: 'anthropic',\n                                                    },\n                                                    body: {\n                                                        type: 'oauth',\n                                                        refresh: json.refresh_token,\n                                                        access: json.access_token,\n                                                        expires: Date.now() + json.expires_in * 1000,\n                                                    },\n                                                });\n                                                return json.access_token;\n                                            }\n                                            catch (error) {\n                                                const isNetworkError = error instanceof Error &&\n                                                    (error.message.includes('fetch failed') ||\n                                                        ('code' in error &&\n                                                            (error.code === 'ECONNRESET' ||\n                                                                error.code === 'ECONNREFUSED' ||\n                                                                error.code === 'ETIMEDOUT' ||\n                                                                error.code === 'UND_ERR_CONNECT_TIMEOUT')));\n                                                if (attempt < maxRetries && isNetworkError) {\n                                                    continue;\n                                                }\n                                                throw error;\n                                            }\n                                        }\n                                        // Unreachable — each iteration either returns or throws.\n                                        // Kept as a TypeScript exhaustiveness guard.\n                                        throw new Error('Token refresh exhausted all retries');\n                                    })().finally(() => {\n                                        refreshPromise = null;\n                                    });\n                                }\n                                auth.access = await refreshPromise;\n                            }\n"""

new_if = """                            if (!auth.access || !auth.expires || auth.expires < Date.now() + 60000) {\n                                auth.access = await refreshOrSync();\n                            }\n"""

if "auth.expires < Date.now() + 60000" not in src or "return await syncFromClaudeCli();" not in src:
    if old_if not in src:
        print("    unsupported upstream index.js layout (refresh block not found)", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_if, new_if, 1)

old_fetch = """                            const response = await fetch(rewritten.input, {\n                                ...init,\n                                body,\n                                headers: requestHeaders,\n                                ...(isInsecure() && { tls: { rejectUnauthorized: false } }),\n                            });\n                            return createStrippedStream(response);\n"""

new_fetch = """                            const sendRequest = async (headers) => await fetch(rewritten.input, {\n                                ...init,\n                                body,\n                                headers,\n                                ...(isInsecure() && { tls: { rejectUnauthorized: false } }),\n                            });\n                            const isRetryableAuthFailure = async (response) => {\n                                if (response.status === 401 || response.status === 403) {\n                                    return true;\n                                }\n                                if (response.status !== 400) {\n                                    return false;\n                                }\n                                const bodyText = await response.clone().text().catch(() => '');\n                                const lowered = bodyText.toLowerCase();\n                                return lowered.includes('invalid authentication credentials') ||\n                                    (lowered.includes('authentication') && lowered.includes('invalid'));\n                            };\n                            let response = await sendRequest(requestHeaders);\n                            if (await isRetryableAuthFailure(response)) {\n                                auth.access = await refreshOrSync();\n                                const retryHeaders = new Headers(requestHeaders);\n                                setOAuthHeaders(retryHeaders, auth.access);\n                                response = await sendRequest(retryHeaders);\n                            }\n                            return createStrippedStream(response);\n"""

if "const sendRequest = async (headers) => await fetch(rewritten.input, {" not in src:
    if old_fetch not in src:
        print("    unsupported upstream index.js layout (request fetch block not found)", file=sys.stderr)
        sys.exit(1)
    src = src.replace(old_fetch, new_fetch, 1)

index_path.write_text(src)
PY

ok "refreshes early, force-refreshes bad live tokens, and falls back to Claude CLI when refresh is unavailable"

# ─── Update opencode.json ────────────────────────────────────────────────────
step "Updating $CONFIG_PATH"

mkdir -p "$(dirname "$CONFIG_PATH")"
if [ -f "$CONFIG_PATH" ]; then
  BAK="$CONFIG_PATH.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_PATH" "$BAK"
  ok "backup: $BAK"
fi

CONFIG_PATH="$CONFIG_PATH" PLUGIN_REF="$PLUGIN_REF" "$PY_BIN" - <<'PY' || fail "failed to update $CONFIG_PATH"
import json, os, sys
path = os.environ["CONFIG_PATH"]
plug = os.environ["PLUGIN_REF"]

cfg = {}
if os.path.isfile(path):
    with open(path, "r") as f:
        raw = f.read().strip()
    if raw:
        try:
            cfg = json.loads(raw)
        except Exception as e:
            print(f"    existing {path} is not valid JSON: {e}", file=sys.stderr)
            sys.exit(1)

if "$schema" not in cfg:
    cfg["$schema"] = "https://opencode.ai/config.json"

plugins = cfg.get("plugin")
if not isinstance(plugins, list):
    plugins = []

# Remove any conflicting plugins on the anthropic auth slot.
keep = []
for p in plugins:
    if p == "opencode-claude-bridge":
        continue
    if p == "opencode-claude-code-plugin":
        continue
    if isinstance(p, str) and "/opencode-anthropic-auth/" in p:
        continue
    keep.append(p)
if plug not in keep:
    keep.append(plug)
cfg["plugin"] = keep

providers = cfg.get("provider")
if not isinstance(providers, dict):
    providers = {}
providers.pop("claude-proxy", None)
providers.pop("claude-code", None)
cfg["provider"] = providers

current = cfg.get("model") or ""
if (not current) or current.startswith("claude-code/") or current.startswith("claude-proxy/"):
    cfg["model"] = "anthropic/claude-sonnet-4-6"

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print("    plugin: " + json.dumps(cfg["plugin"]))
print("    model:  " + cfg["model"])
PY

ok "plugin registered, legacy entries removed"

# ─── Install proactive token refresh ─────────────────────────────────────────
if [ -n "${NODE_BIN:-}" ]; then
step "Installing proactive token refresh daemon"

cat > "$REPO_ENTRY_DIR/refresh-token.mjs" <<'REFRESH_JS'
#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, appendFileSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const HOME = homedir();
const PLUGIN_DIR = process.env.OPENCODE_ANTHROPIC_AUTH_DIR || join(HOME, '.local/share/opencode-anthropic-auth');
const AUTH_PATH = process.env.OPENCODE_AUTH_PATH || join(HOME, '.local/share/opencode/auth.json');
const LOG_PATH = join(PLUGIN_DIR, 'refresh.log');
const SYNC_MODEL = process.env.OPENCODE_ANTHROPIC_AUTH_CLAUDE_SYNC_MODEL || 'claude-sonnet-4-6';
const TIMEOUT_MS = 30000;
const TTL_MS = 14400000;
const REFRESH_THRESHOLD_MS = 3600000;  // 1h buffer (was 2h); combined with 45min interval keeps token inside inactivity window

function log(msg) {
    const line = `[${new Date().toISOString()}] ${msg}\n`;
    try { appendFileSync(LOG_PATH, line); } catch {}
    process.stderr.write(line);
}

async function tryOAuthRefresh(refreshToken) {
    let CLIENT_ID, TOKEN_URL;
    try {
        const mod = await import(pathToFileURL(join(PLUGIN_DIR, 'dist/constants.js')).href);
        CLIENT_ID = mod.CLIENT_ID;
        TOKEN_URL = mod.TOKEN_URL;
    } catch { return null; }
    const res = await fetch(TOKEN_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/plain, */*', 'User-Agent': 'axios/1.13.6' },
        body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: refreshToken, client_id: CLIENT_ID }),
    });
    if (!res.ok) { const body = await res.text().catch(() => ''); throw new Error(`${res.status}: ${body.slice(0, 200)}`); }
    const json = await res.json();
    return { access: json.access_token, refresh: json.refresh_token, expires: Date.now() + json.expires_in * 1000 };
}

function resolveClaudeBin() {
    for (const c of [process.env.CLAUDE_BIN, join(HOME, '.local/bin/claude'), join(HOME, '.claude/local/claude'), '/opt/homebrew/bin/claude', '/usr/local/bin/claude', 'claude'].filter(Boolean))
        if (c === 'claude' || existsSync(c)) return c;
    return 'claude';
}

function captureBearer() {
    return new Promise((resolve, reject) => {
        let child = null, settled = false, timeout = null;
        const finish = (fn, val) => { if (settled) return; settled = true; if (timeout) clearTimeout(timeout); server.close(); if (child?.exitCode === null) child.kill('SIGTERM'); fn(val); };
        const server = createServer((req, res) => {
            if (req.method === 'HEAD') { res.writeHead(200); res.end(); return; }
            if (req.method === 'POST' && req.url?.startsWith('/v1/messages')) {
                const auth = req.headers.authorization; res.writeHead(204); res.end();
                if (typeof auth === 'string' && auth.startsWith('Bearer ')) finish(resolve, auth.slice(7));
                else finish(reject, new Error('No bearer in captured request'));
                return;
            }
            res.writeHead(404); res.end();
        });
        server.on('error', e => finish(reject, e));
        server.listen(0, '127.0.0.1', () => {
            const addr = server.address();
            if (!addr || typeof addr === 'string') { finish(reject, new Error('Bind failed')); return; }
            child = spawn(resolveClaudeBin(), ['--print', 'AUTH_REFRESH_OK', '--model', SYNC_MODEL], {
                cwd: HOME, env: { ...process.env, ANTHROPIC_BASE_URL: `http://127.0.0.1:${addr.port}` }, stdio: ['ignore', 'ignore', 'pipe'],
            });
            let stderr = '';
            child.stderr.on('data', chunk => { stderr += chunk; });
            child.on('error', e => finish(reject, e));
            child.on('exit', code => { if (!settled) finish(reject, new Error(`claude exited (${code})${stderr ? ' — ' + stderr.slice(0, 200) : ''}`)); });
        });
        timeout = setTimeout(() => finish(reject, new Error('Timeout')), TIMEOUT_MS);
    });
}

async function main() {
    try { if (existsSync(LOG_PATH) && statSync(LOG_PATH).size > 102400) { const l = readFileSync(LOG_PATH, 'utf8').split('\n'); writeFileSync(LOG_PATH, l.slice(-50).join('\n')); } } catch {}
    if (!existsSync(AUTH_PATH)) { log('SKIP: no auth.json'); return; }
    let store;
    try { store = JSON.parse(readFileSync(AUTH_PATH, 'utf8')); } catch (e) { log(`ERROR: ${e.message}`); process.exit(1); }
    const entry = store.anthropic;
    if (!entry || entry.type !== 'oauth') { log('SKIP: no anthropic oauth entry'); return; }
    const remaining = (entry.expires || 0) - Date.now();
    if (remaining > REFRESH_THRESHOLD_MS) { log(`SKIP: ${(remaining / 3600000).toFixed(1)}h remaining`); return; }
    log(remaining > 0 ? `${(remaining / 60000).toFixed(0)}min remaining — refreshing` : 'Expired — refreshing');
    try {
        const access = await captureBearer();
        store.anthropic = { ...entry, access, expires: Date.now() + TTL_MS };
        writeFileSync(AUTH_PATH, JSON.stringify(store, null, 2) + '\n');
        log(`OK (cli): expires in ${(TTL_MS / 3600000).toFixed(0)}h`);
        return;
    } catch (e) { log(`CLI capture failed (${e.message}), trying OAuth refresh`); }
    if (entry.refresh) {
        try {
            const result = await tryOAuthRefresh(entry.refresh);
            if (result) { store.anthropic = { ...entry, ...result }; writeFileSync(AUTH_PATH, JSON.stringify(store, null, 2) + '\n'); log(`OK (oauth): expires in ${((result.expires - Date.now()) / 3600000).toFixed(1)}h`); return; }
        } catch (e) { log(`FAIL: both CLI and OAuth failed — OAuth: ${e.message}`); process.exit(1); }
    }
    log('FAIL: CLI capture failed and no refresh token available'); process.exit(1);
}
main();
REFRESH_JS

chmod +x "$REPO_ENTRY_DIR/refresh-token.mjs"
ok "refresh script: $REPO_ENTRY_DIR/refresh-token.mjs"

# ─── Install recovery helper ────────────────────────────────────────────────
step "Installing auth recovery helper"

cat > "$REPO_ENTRY_DIR/recover.sh" <<'RECOVER_SH'
#!/usr/bin/env bash
# opencode-anthropic-auth recover
# Usage: recover.sh
# Runs `claude setup-token`, captures the printed token,
# writes it into auth.json, and triggers a normal refresh
# to re-establish a paired access+refresh token.

set -euo pipefail

AUTH_JSON="${OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"
PLUGIN_DIR="${OPENCODE_ANTHROPIC_AUTH_DIR:-$HOME/.local/share/opencode-anthropic-auth}"

echo "┌──────────────────────────────────────────────────────┐"
echo "│  opencode-anthropic-auth: token recovery             │"
echo "└──────────────────────────────────────────────────────┘"
echo
echo "This will:"
echo "  1. Open a browser for one-time Anthropic OAuth login"
echo "  2. Write the new token into your opencode auth.json"
echo "  3. Run a normal refresh to re-establish paired tokens"
echo
echo "Press Enter to continue (or Ctrl-C to abort)..."
read -r _

# Pre-flight: this requires a browser (setup-token opens claude.ai/oauth)
# If run over pure SSH without display forwarding, setup-token will hang.
if [ "$(uname)" = "Darwin" ]; then
  # On macOS, `open` works for GUI apps even without DISPLAY set.
  :
elif [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
  echo "ERROR: no display detected. claude setup-token needs a browser."
  echo "       Run this on your local Mac (not over SSH), or:"
  echo "       1) Run \`claude setup-token\` on a machine with a browser"
  echo "       2) Copy the sk-ant-oat01-... token it prints"
  echo "       3) Paste here: CLAUDE_CODE_OAUTH_TOKEN=<token> $0"
  exit 2
fi

# Step 1: Run claude setup-token (interactive, opens browser)
# Accept the token either from $CLAUDE_CODE_OAUTH_TOKEN env var (manual-paste path)
# or by capturing it from the setup-token command output. Extract with a
# non-anchored regex so surrounding text ("Your token: sk-...") still matches.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  echo "-> Using token from \$CLAUDE_CODE_OAUTH_TOKEN"
  TOKEN="$CLAUDE_CODE_OAUTH_TOKEN"
else
  echo "-> Running: claude setup-token  (browser will open)"
  TOKEN=$(claude setup-token 2>&1 | grep -oE 'sk-ant-oat01-[A-Za-z0-9_-]+' | head -n 1 || true)
fi
if [ -z "$TOKEN" ]; then
  echo "Did not auto-capture a token. Paste it now (or Ctrl-C to abort):"
  read -r TOKEN
fi
if [[ ! "$TOKEN" =~ ^sk-ant-oat01- ]]; then
  echo "ERROR: token format unexpected: ${TOKEN:0:20}..."
  exit 1
fi

# Step 2: Write into auth.json (preserve other fields)
mkdir -p "$(dirname "$AUTH_JSON")"
if [ -f "$AUTH_JSON" ]; then
  cp "$AUTH_JSON" "$AUTH_JSON.bak.$(date +%s)"
fi
python3 - <<PY
import json, os, sys, time
path = "$AUTH_JSON"
token = "$TOKEN"
try:
    with open(path) as f:
        store = json.load(f)
except FileNotFoundError:
    store = {}
store.setdefault("anthropic", {})
store["anthropic"]["type"] = "oauth"
store["anthropic"]["access"] = token
# Leave "refresh" untouched if present (setup-token has no refresh counterpart).
# expires far-future so daemon treats token as healthy; CLI capture below will
# establish proper paired refresh token within seconds.
store["anthropic"]["expires"] = int((time.time() + 300) * 1000)
with open(path, "w") as f:
    json.dump(store, f, indent=2)
print(f"-> wrote token into {path}")
PY

# Step 3: Trigger normal refresh to establish paired refresh token
NODE_BIN=$(command -v node || echo /opt/homebrew/bin/node)
echo "-> running normal refresh to establish paired tokens..."
"$NODE_BIN" "$PLUGIN_DIR/refresh-token.mjs" || {
  echo "  (first refresh may fail -- token is still usable; next LaunchAgent run will fix it)"
}

echo "Recovery complete. Try: claude \"ping\""
RECOVER_SH
chmod +x "$REPO_ENTRY_DIR/recover.sh"
ok "recovery helper: $REPO_ENTRY_DIR/recover.sh"
note "if auth dies, run: $REPO_ENTRY_DIR/recover.sh"

# ─── Install auth reset helper ────────────────────────────────────────────────
step "Installing auth reset helper"

cat > "$REPO_ENTRY_DIR/reset.sh" <<'RESET_SH'
#!/usr/bin/env bash
set -euo pipefail

AUTH_JSON="${OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"

if [ "${1:-}" != "--yes" ]; then
  echo "This deletes the stored Anthropic OAuth entry from: $AUTH_JSON"
  echo "Use this when you want a clean slate before logging in again."
  echo
  echo "Run again with: $0 --yes"
  exit 1
fi

python3 - <<PY
import json, os
path = os.path.expanduser(${AUTH_JSON@Q})
if not os.path.exists(path):
    print(f"No auth file at {path}; nothing to delete.")
    raise SystemExit(0)
with open(path) as f:
    data = json.load(f)
if 'anthropic' in data:
    data.pop('anthropic', None)
    with open(path, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print(f"Deleted anthropic OAuth entry from {path}")
else:
    print(f"No anthropic OAuth entry found in {path}")
PY

echo
echo "Next steps:"
echo "  1. Run: claude auth login"
echo "  2. Run: $HOME/.local/share/opencode-anthropic-auth/recover.sh"
echo "  3. Retry your Claude/OpenCode command"
RESET_SH

chmod +x "$REPO_ENTRY_DIR/reset.sh"
ok "reset helper: $REPO_ENTRY_DIR/reset.sh"
note "clean slate: $REPO_ENTRY_DIR/reset.sh --yes"

# ─── Install unified doctor ─────────────────────────────────────────────────
step "Installing unified doctor (status/refresh/doctor/env)"

cat > "$REPO_ENTRY_DIR/doctor.mjs" <<'DOCTOR_JS'
#!/usr/bin/env node
// opencode-anthropic-auth doctor
// Single entrypoint for Anthropic OAuth token health.
//
// Subcommands:
//   status  [--json] [--verbose]   diagnose only; exit reflects state
//   refresh [--force] [--json]     force a refresh (or noop if HEALTHY)
//   doctor  [--fix]  [--json]      diagnose; if --fix, auto-remediate up to relogin boundary
//   env                            emit shell exports (CLAUDE_CODE_OAUTH_* ) if HEALTHY, else exit nonzero
//
// Exit codes:
//   0  HEALTHY (or fixed to HEALTHY)
//   1  FIXABLE (near-expiry, transient, VPS stale, VPS unreachable, network down)
//   2  TERMINAL (refresh token dead, auth.json missing/corrupt, must re-login)

import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const HOME = homedir();
const PLUGIN_DIR = process.env.OPENCODE_ANTHROPIC_AUTH_DIR || join(HOME, '.local/share/opencode-anthropic-auth');
const AUTH_PATH = process.env.OPENCODE_AUTH_PATH || join(HOME, '.local/share/opencode/auth.json');
const VPS_CONFIG = join(PLUGIN_DIR, '.vps-config');
const PULL_SCRIPT = join(PLUGIN_DIR, 'pull-from-vps.sh');
const RECOVER_SCRIPT = join(PLUGIN_DIR, 'recover.sh');
const RESET_SCRIPT = join(PLUGIN_DIR, 'reset.sh');
const LOG_PATH = join(PLUGIN_DIR, 'refresh.log');
const FRESH_MS = 10 * 60 * 1000;

const FALLBACK_CLIENT_ID = '9d1c250a-e61b-44d9-88ed-5944d1962f5e';
const FALLBACK_TOKEN_URL = 'https://platform.claude.com/v1/oauth/token';
const DEFAULT_SCOPES = 'user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload org:create_api_key';

const STATES = {
  HEALTHY:            { exit: 0, glyph: '✓', msg: 'token fresh' },
  NEEDS_REFRESH:      { exit: 1, glyph: '⚠', msg: 'token near expiry, refresh token present' },
  VPS_STALE:          { exit: 1, glyph: '⚠', msg: 'VPS mode; local token behind VPS, pull needed' },
  VPS_UNREACHABLE:    { exit: 1, glyph: '⚠', msg: 'VPS mode; VPS unreachable via Tailnet' },
  AUTH_JSON_MISSING:  { exit: 2, glyph: '✗', msg: 'auth.json not found' },
  AUTH_JSON_CORRUPT:  { exit: 2, glyph: '✗', msg: 'auth.json is not valid JSON' },
  NO_ANTHROPIC_ENTRY: { exit: 2, glyph: '✗', msg: 'auth.json has no anthropic oauth entry' },
  REFRESH_TOKEN_DEAD: { exit: 2, glyph: '✗', msg: 'refresh token rejected — must re-login' },
  TRANSIENT:          { exit: 1, glyph: '⚠', msg: 'transient upstream error' },
  NETWORK_DOWN:       { exit: 1, glyph: '⚠', msg: 'network unreachable' },
};

function log(msg) {
  const line = `[${new Date().toISOString()}] doctor: ${msg}\n`;
  try { appendFileSync(LOG_PATH, line); } catch {}
}

function readVpsConfig() {
  if (!existsSync(VPS_CONFIG)) return null;
  const cfg = {};
  for (const line of readFileSync(VPS_CONFIG, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m) cfg[m[1]] = m[2].trim();
  }
  return cfg;
}

function readAuth() {
  if (!existsSync(AUTH_PATH)) return { state: 'AUTH_JSON_MISSING' };
  let raw;
  try { raw = readFileSync(AUTH_PATH, 'utf8'); }
  catch (e) { return { state: 'AUTH_JSON_CORRUPT', error: String(e.message || e) }; }
  let json;
  try { json = JSON.parse(raw); }
  catch (e) { return { state: 'AUTH_JSON_CORRUPT', error: String(e.message || e) }; }
  const entry = json && json.anthropic;
  if (!entry || entry.type !== 'oauth') return { state: 'NO_ANTHROPIC_ENTRY', json };
  return { json, entry };
}

function writeAuth(json) {
  writeFileSync(AUTH_PATH, JSON.stringify(json, null, 2) + '\n');
}

function classifyOAuthError(status, bodyText) {
  const lower = (bodyText || '').toLowerCase();
  if (status === 400 && (lower.includes('invalid_grant') || lower.includes('invalid_scope') || lower.includes('refresh token'))) return 'REFRESH_TOKEN_DEAD';
  if (status === 401 && (lower.includes('authentication_error') || lower.includes('invalid authentication credentials') || lower.includes('oauth token'))) return 'REFRESH_TOKEN_DEAD';
  if (status === 529 || status === 503 || status === 504) return 'TRANSIENT';
  return 'TRANSIENT';
}

async function loadConstants() {
  try {
    const mod = await import(pathToFileURL(join(PLUGIN_DIR, 'dist/constants.js')).href);
    return { CLIENT_ID: mod.CLIENT_ID || FALLBACK_CLIENT_ID, TOKEN_URL: mod.TOKEN_URL || FALLBACK_TOKEN_URL };
  } catch {
    return { CLIENT_ID: FALLBACK_CLIENT_ID, TOKEN_URL: FALLBACK_TOKEN_URL };
  }
}

async function oauthRefresh(refreshToken) {
  const { CLIENT_ID, TOKEN_URL } = await loadConstants();
  let res;
  try {
    res = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/plain, */*', 'User-Agent': 'axios/1.13.6' },
      body: JSON.stringify({ grant_type: 'refresh_token', refresh_token: refreshToken, client_id: CLIENT_ID }),
    });
  } catch (e) {
    return { ok: false, state: 'NETWORK_DOWN', error: String(e.message || e) };
  }
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    return { ok: false, state: classifyOAuthError(res.status, body), status: res.status, body: body.slice(0, 400) };
  }
  let json;
  try { json = await res.json(); }
  catch (e) { return { ok: false, state: 'TRANSIENT', error: String(e.message || e) }; }
  return { ok: true, access: json.access_token, refresh: json.refresh_token || refreshToken, expires: Date.now() + (json.expires_in || 28800) * 1000 };
}

function pullFromVps() {
  if (!existsSync(PULL_SCRIPT)) return { ok: false, reason: 'pull script missing' };
  const res = spawnSync(PULL_SCRIPT, [], { stdio: ['ignore', 'pipe', 'pipe'], timeout: 10000 });
  if (res.error) return { ok: false, reason: String(res.error.message || res.error) };
  if (res.status === 0) return { ok: true };
  return { ok: false, exitCode: res.status, stderr: (res.stderr?.toString() || '').slice(0, 400) };
}

async function diagnose() {
  const auth = readAuth();
  const vps = readVpsConfig();
  const mode = vps ? 'vps-offload' : 'mac-only';
  if (auth.state) return { state: auth.state, mode, vps_configured: Boolean(vps), error: auth.error };
  const { entry } = auth;
  const now = Date.now();
  const expires = entry.expires || 0;
  const remainingMs = expires - now;
  const base = {
    mode,
    vps_configured: Boolean(vps),
    auth_path: AUTH_PATH,
    expires_at: expires ? new Date(expires).toISOString() : null,
    remaining_sec: Math.round(remainingMs / 1000),
    remaining_min: Math.round(remainingMs / 60000),
    remaining_hours: Math.round((remainingMs / 3600000) * 10) / 10,
    has_refresh_token: Boolean(entry.refresh),
  };
  if (remainingMs > FRESH_MS) return { state: 'HEALTHY', ...base };
  if (mode === 'vps-offload') return { state: 'VPS_STALE', ...base };
  return { state: 'NEEDS_REFRESH', ...base };
}

async function localRefreshFlow() {
  const auth = readAuth();
  if (auth.state) return { fixed: false, newState: auth.state };
  if (!auth.entry.refresh) return { fixed: false, newState: 'REFRESH_TOKEN_DEAD', detail: 'no refresh token in auth.json' };
  const result = await oauthRefresh(auth.entry.refresh);
  if (result.ok) {
    auth.json.anthropic = { ...auth.entry, access: result.access, refresh: result.refresh, expires: result.expires };
    writeAuth(auth.json);
    const h = Math.round(((result.expires - Date.now()) / 3600000) * 10) / 10;
    log(`fix(local): OAuth refresh OK, expires in ${h}h`);
    return { fixed: true, newState: 'HEALTHY' };
  }
  log(`fix(local): OAuth refresh failed state=${result.state} status=${result.status || '-'} body=${(result.body || result.error || '').toString().slice(0, 200)}`);
  return { fixed: false, newState: result.state, detail: result.body || result.error };
}

async function attemptFix(diag) {
  if (diag.state === 'HEALTHY') return { fixed: true, newState: 'HEALTHY' };

  if (diag.state === 'VPS_STALE' || diag.state === 'VPS_UNREACHABLE') {
    const pull = pullFromVps();
    if (pull.ok) {
      const after = await diagnose();
      if (after.state === 'HEALTHY') {
        log('fix(vps): pull-from-vps → HEALTHY');
        return { fixed: true, newState: 'HEALTHY' };
      }
      if (after.has_refresh_token) return localRefreshFlow();
      return { fixed: false, newState: after.state, detail: 'VPS pull succeeded but result not HEALTHY' };
    }
    log(`fix(vps): pull-from-vps failed exit=${pull.exitCode || '-'} stderr=${(pull.stderr || pull.reason || '').toString().slice(0, 200)}`);
    if (diag.has_refresh_token) return localRefreshFlow();
    return { fixed: false, newState: 'VPS_UNREACHABLE', detail: pull.stderr || pull.reason };
  }

  if (diag.state === 'NEEDS_REFRESH') return localRefreshFlow();

  return { fixed: false, newState: diag.state, detail: 'state is terminal, requires re-login' };
}

function suggestedAction(state) {
  switch (state) {
    case 'HEALTHY': return null;
    case 'NEEDS_REFRESH': return 'run: node ' + join(PLUGIN_DIR, 'doctor.mjs') + ' doctor --fix';
    case 'VPS_STALE':
    case 'VPS_UNREACHABLE': return 'run: ' + PULL_SCRIPT;
    case 'AUTH_JSON_MISSING':
    case 'AUTH_JSON_CORRUPT':
    case 'NO_ANTHROPIC_ENTRY':
    case 'REFRESH_TOKEN_DEAD': return 'run: ' + RECOVER_SCRIPT;
    case 'NETWORK_DOWN':
    case 'TRANSIENT': return 'retry later (transient upstream or network error)';
    default: return null;
  }
}

function nextSteps(state) {
  switch (state) {
    case 'HEALTHY':
      return [];
    case 'NEEDS_REFRESH':
      return [
        `1. Run: node ${join(PLUGIN_DIR, 'doctor.mjs')} doctor --fix`,
        '2. Retry your Claude/OpenCode command',
      ];
    case 'VPS_STALE':
    case 'VPS_UNREACHABLE':
      return [
        `1. Run: ${PULL_SCRIPT}`,
        '2. If that fails, check Tailscale / SSH / VPS health',
        '3. Retry your Claude/OpenCode command',
      ];
    case 'AUTH_JSON_MISSING':
    case 'NO_ANTHROPIC_ENTRY':
      return [
        '1. Run: claude auth login',
        `2. Run: ${RECOVER_SCRIPT}`,
        '3. Retry your Claude/OpenCode command',
      ];
    case 'AUTH_JSON_CORRUPT':
      return [
        `1. Inspect or remove: ${AUTH_PATH}`,
        '2. Run: claude auth login',
        `3. Run: ${RECOVER_SCRIPT}`,
      ];
    case 'REFRESH_TOKEN_DEAD':
      return [
        '1. Run: claude auth login',
        `2. Run: ${RECOVER_SCRIPT}`,
        `3. If you want a clean slate first: ${RESET_SCRIPT} --yes`,
        '4. Retry your Claude/OpenCode command',
      ];
    case 'NETWORK_DOWN':
      return [
        '1. Reconnect to the internet or tailnet',
        '2. Retry later with: node ' + join(PLUGIN_DIR, 'doctor.mjs') + ' refresh --force',
      ];
    case 'TRANSIENT':
      return [
        '1. Wait a minute and retry',
        '2. If it keeps happening, run: node ' + join(PLUGIN_DIR, 'doctor.mjs') + ' refresh --force',
      ];
    default:
      return [];
  }
}

function formatHuman(diag, fixResult) {
  const info = STATES[diag.state] || { glyph: '?', msg: 'unknown state' };
  const out = [];
  out.push(`${info.glyph}  ${diag.state}  —  ${info.msg}`);
  if (diag.mode) out.push(`   mode: ${diag.mode}`);
  if (diag.auth_path) out.push(`   auth: ${diag.auth_path}`);
  if (diag.expires_at) out.push(`   expires: ${diag.expires_at} (${diag.remaining_hours}h remaining)`);
  if (diag.has_refresh_token !== undefined) out.push(`   refresh_token: ${diag.has_refresh_token ? 'present' : 'missing'}`);
  if (diag.error) out.push(`   error: ${diag.error}`);
  if (fixResult) {
    out.push('');
    if (fixResult.fixed) out.push(`→ fixed → ${fixResult.newState}`);
    else out.push(`→ could not fix (${fixResult.newState})${fixResult.detail ? ': ' + fixResult.detail : ''}`);
  }
  const next = suggestedAction(fixResult?.newState || diag.state);
  if (next) { out.push(''); out.push(`next: ${next}`); }
  const steps = nextSteps(fixResult?.newState || diag.state);
  if (steps.length) {
    out.push('');
    out.push('what to do:');
    for (const step of steps) out.push(`   ${step}`);
  }
  return out.join('\n');
}

function shellEsc(s) { return `'${String(s).replace(/'/g, `'\\''`)}'`; }

async function main() {
  const argv = process.argv.slice(2);
  const sub = argv[0] || 'status';
  const flags = new Set(argv.slice(1));
  const json = flags.has('--json');
  const fix = flags.has('--fix');
  const force = flags.has('--force');

  if (sub === 'status') {
    const diag = await diagnose();
    if (json) process.stdout.write(JSON.stringify({ ...diag, suggested_action: suggestedAction(diag.state), next_steps: nextSteps(diag.state) }, null, 2) + '\n');
    else process.stdout.write(formatHuman(diag) + '\n');
    process.exit((STATES[diag.state] || { exit: 2 }).exit);
  }

  if (sub === 'refresh') {
    let diag = await diagnose();
    if (!force && diag.state === 'HEALTHY') {
      if (json) process.stdout.write(JSON.stringify({ ...diag, action: 'noop' }, null, 2) + '\n');
      else process.stdout.write(`${STATES.HEALTHY.glyph}  HEALTHY  —  noop (use --force to refresh anyway)\n`);
      process.exit(0);
    }
    const fixResult = await attemptFix(force ? { ...diag, state: diag.state === 'HEALTHY' ? 'NEEDS_REFRESH' : diag.state } : diag);
    diag = await diagnose();
    const effectiveState = fixResult && !fixResult.fixed ? fixResult.newState : diag.state;
    if (json) process.stdout.write(JSON.stringify({ ...diag, effective_state: effectiveState, fix_result: fixResult, suggested_action: suggestedAction(effectiveState), next_steps: nextSteps(effectiveState) }, null, 2) + '\n');
    else process.stdout.write(formatHuman({ ...diag, state: effectiveState }, fixResult) + '\n');
    process.exit((STATES[effectiveState] || { exit: 2 }).exit);
  }

  if (sub === 'doctor') {
    let diag = await diagnose();
    let fixResult = null;
    if (fix && diag.state !== 'HEALTHY') { fixResult = await attemptFix(diag); diag = await diagnose(); }
    const effectiveState = fixResult && !fixResult.fixed ? fixResult.newState : diag.state;
    if (json) process.stdout.write(JSON.stringify({ ...diag, effective_state: effectiveState, fix_result: fixResult, suggested_action: suggestedAction(effectiveState), next_steps: nextSteps(effectiveState) }, null, 2) + '\n');
    else process.stdout.write(formatHuman({ ...diag, state: effectiveState }, fixResult) + '\n');
    process.exit((STATES[effectiveState] || { exit: 2 }).exit);
  }

  if (sub === 'env') {
    const diag = await diagnose();
    if (diag.state !== 'HEALTHY') process.exit(1);
    const auth = readAuth();
    if (auth.state) process.exit(2);
    process.stdout.write(`export CLAUDE_CODE_OAUTH_TOKEN=${shellEsc(auth.entry.access)}\n`);
    process.stdout.write(`export CLAUDE_CODE_OAUTH_REFRESH_TOKEN=${shellEsc(auth.entry.refresh)}\n`);
    process.stdout.write(`export CLAUDE_CODE_OAUTH_SCOPES=${shellEsc(DEFAULT_SCOPES)}\n`);
    process.exit(0);
  }

  process.stderr.write('usage: doctor.mjs <status|refresh|doctor|env> [--json] [--verbose] [--fix] [--force]\n');
  process.exit(64);
}

main().catch(e => { process.stderr.write(`doctor: fatal: ${e.stack || e.message}\n`); process.exit(2); });
DOCTOR_JS

chmod +x "$REPO_ENTRY_DIR/doctor.mjs"
ok "doctor: $REPO_ENTRY_DIR/doctor.mjs"
note "status: node $REPO_ENTRY_DIR/doctor.mjs status [--json]"
note "fix:    node $REPO_ENTRY_DIR/doctor.mjs doctor --fix"
note "force:  node $REPO_ENTRY_DIR/doctor.mjs refresh --force"
note "exit:   0 healthy | 1 fixable | 2 must-relogin"

if [ "$MODE" = "vps-offload" ]; then
  step "Skipping local refresh daemon (VPS-offload mode)"
  note "VPS handles token refresh on a 30-minute systemd timer."
  note "Mac pulls fresh tokens on demand via pull-from-vps.sh (installed below)."
  note "If a legacy LaunchAgent is loaded from a prior Mac-only install, unloading it."

  if [ "$(uname)" = "Darwin" ]; then
    PLIST_LABEL="com.opencode-anthropic-auth.refresh"
    PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    if [ -f "$PLIST_PATH" ]; then
      mv "$PLIST_PATH" "$PLIST_PATH.disabled-$(date +%s)" 2>/dev/null || true
      note "disabled legacy plist: $PLIST_PATH.disabled-*"
    fi
  else
    (crontab -l 2>/dev/null | grep -v "refresh-token.mjs" || true) | crontab - 2>/dev/null || true
  fi
elif [ "$INSTALL_MODE" = "manual" ]; then
  step "Skipping local refresh daemon (manual mode)"
  note "Manual mode installs the wrapper and doctor only."
  note "Refresh manually with: node $REPO_ENTRY_DIR/doctor.mjs refresh --force"
elif [ "$(uname)" = "Darwin" ]; then
  PLIST_LABEL="com.opencode-anthropic-auth.refresh"
  PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"

  launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true

  if [ -f "$PLIST_PATH" ]; then
    cp "$PLIST_PATH" "$PLIST_PATH.bak.$(date +%s)" 2>/dev/null || true
    note "old plist backed up: $PLIST_PATH.bak.*"
  fi

  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-i</string>
        <string>-t</string>
        <string>180</string>
        <string>${NODE_BIN}</string>
        <string>${REPO_ENTRY_DIR}/refresh-token.mjs</string>
    </array>
    <key>StartInterval</key>
    <integer>2700</integer>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Minute</key><integer>15</integer></dict>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${REPO_ENTRY_DIR}/refresh.log</string>
    <key>StandardErrorPath</key>
    <string>${REPO_ENTRY_DIR}/refresh.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin</string>
    </dict>
</dict>
</plist>
PLIST

  launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null \
    || launchctl load "$PLIST_PATH" 2>/dev/null \
    || warn "could not load LaunchAgent — run: launchctl load $PLIST_PATH"
  ok "LaunchAgent: $PLIST_PATH (every 45min + hourly wake-from-sleep)"
  note "Log: $REPO_ENTRY_DIR/refresh.log"
else
  CRON_CMD="*/45 * * * * ${NODE_BIN} ${REPO_ENTRY_DIR}/refresh-token.mjs >> ${REPO_ENTRY_DIR}/refresh.log 2>&1"
  ( crontab -l 2>/dev/null | grep -v "refresh-token.mjs"; echo "$CRON_CMD" ) | crontab - 2>/dev/null \
    || warn "could not install cron — add manually: $CRON_CMD"
  ok "cron: refreshes every 45 minutes"
  note "Log: $REPO_ENTRY_DIR/refresh.log"
fi

else
  warn "Skipping proactive refresh daemon (node not found)"
  note "Plugin still works reactively — but idle tokens may expire"
fi

if [ "$MODE" = "vps-offload" ]; then
step "Installing VPS-offload pull helper"

if [ -n "${OCAUTH_VPS_HOST:-}" ]; then
  : "${OCAUTH_TS_IP:?OCAUTH_TS_IP is required in VPS-offload mode}"
  : "${OCAUTH_BEARER:?OCAUTH_BEARER is required in VPS-offload mode}"
  OCAUTH_PORT="${OCAUTH_PORT:-8787}"
  cat > "$VPS_CONFIG" <<EOF
OCAUTH_HOST=${OCAUTH_VPS_HOST}
OCAUTH_TS_IP=${OCAUTH_TS_IP}
OCAUTH_PORT=${OCAUTH_PORT}
OCAUTH_BEARER=${OCAUTH_BEARER}
EOF
  chmod 600 "$VPS_CONFIG"
  ok "VPS config: $VPS_CONFIG"
fi

cat > "$REPO_ENTRY_DIR/pull-from-vps.sh" <<'PULL_SH'
#!/usr/bin/env bash
set -euo pipefail

PLUGIN_DIR="${OPENCODE_ANTHROPIC_AUTH_DIR:-$HOME/.local/share/opencode-anthropic-auth}"
CONFIG_FILE="$PLUGIN_DIR/.vps-config"
AUTH_PATH="${OPENCODE_AUTH_PATH:-$HOME/.local/share/opencode/auth.json}"
LOG_PATH="$PLUGIN_DIR/refresh.log"

log() {
  local msg="$1"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$LOG_PATH"
}

fail() {
  local code="$1"; shift
  log "FAIL[$code]: $*"
  exit "$code"
}

[[ -f "$CONFIG_FILE" ]] || fail 1 "missing $CONFIG_FILE"
[[ -f "$AUTH_PATH" ]] || fail 3 "missing $AUTH_PATH"
command -v curl >/dev/null 2>&1 || fail 3 "curl not found"
command -v jq >/dev/null 2>&1 || fail 3 "jq not found"

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${OCAUTH_HOST:?missing OCAUTH_HOST}"
: "${OCAUTH_TS_IP:?missing OCAUTH_TS_IP}"
: "${OCAUTH_PORT:?missing OCAUTH_PORT}"
: "${OCAUTH_BEARER:?missing OCAUTH_BEARER}"

# Optional SSH fallback: when Tailscale is off/broken the Mac can still reach
# the VPS over regular SSH and decrypt the token directly. Set OCAUTH_SSH_HOST
# in .vps-config (e.g. the alias from ~/.ssh/config) to enable this path.
SSH_FALLBACK_HOST="${OCAUTH_SSH_HOST:-}"

TMP_RESP="$(mktemp -t ocauth.resp.XXXXXX)"
TMP_OUT="$(mktemp -t ocauth.auth.XXXXXX)"
cleanup() {
  rm -f "$TMP_RESP" "$TMP_OUT"
}
trap cleanup EXIT

fetch_url() {
  local url="$1"
  curl --max-time 5 --connect-timeout 3 -sSf \
    -H "Authorization: Bearer ${OCAUTH_BEARER}" \
    "$url" > "$TMP_RESP"
}

fetch_via_ssh() {
  local host="$1"
  [[ -n "$host" ]] || return 1
  command -v ssh >/dev/null 2>&1 || return 1
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" \
    'sudo age -d -i /opt/ocauth/key.txt /opt/ocauth/token.age' > "$TMP_RESP"
}

SOURCE_LABEL="ssh"
if ! fetch_via_ssh "$SSH_FALLBACK_HOST"; then
  SOURCE_LABEL="fqdn"
  if ! fetch_url "http://${OCAUTH_HOST}:${OCAUTH_PORT}/token"; then
    SOURCE_LABEL="ip"
    if ! fetch_url "http://${OCAUTH_TS_IP}:${OCAUTH_PORT}/token"; then
      fail 1 "network/auth fetch failed via ssh, fqdn, and ip"
    fi
  fi
fi

NOW_MS="$(( $(date +%s) * 1000 ))"
if ! jq -e --argjson now "$NOW_MS" '
  .type == "oauth" and
  (.access | type == "string" and length > 0) and
  (.refresh | type == "string" and length > 0) and
  (.expires | type == "number" and . > $now)
' "$TMP_RESP" >/dev/null; then
  fail 2 "invalid token payload from VPS"
fi

if ! jq --slurpfile new "$TMP_RESP" '.anthropic = $new[0]' "$AUTH_PATH" > "$TMP_OUT"; then
  fail 3 "failed to merge auth.json"
fi

mv -f "$TMP_OUT" "$AUTH_PATH"
chmod 600 "$AUTH_PATH"

EXPIRES_MS="$(jq -r '.expires' "$TMP_RESP")"
REMAINING_H="$(python3 - <<PY
now=${NOW_MS}
exp=${EXPIRES_MS}
print(round((exp-now)/3600000, 2))
PY
)"
log "pull-from-vps OK source=${SOURCE_LABEL} expires_in_h=${REMAINING_H}"
exit 0
PULL_SH

chmod +x "$REPO_ENTRY_DIR/pull-from-vps.sh"
ok "pull helper: $REPO_ENTRY_DIR/pull-from-vps.sh"
note "Wrapper will call this on-demand when <10min remaining or on 401."

JQ_BIN=$(resolve_tool jq /opt/homebrew/bin/jq /usr/local/bin/jq /usr/bin/jq) || true
if [ -z "${JQ_BIN:-}" ]; then
  warn "jq not found on PATH — pull-from-vps.sh requires it"
  if [ "$(uname)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    note "Install with: brew install jq"
  else
    note "Install with your package manager (apt/dnf/pacman): jq"
  fi
fi
fi

step "Installing Claude CLI PATH wrapper"

WRAPPER_SRC_URL="https://raw.githubusercontent.com/iamtheavoc1/opencode-anthropic-auth-fix/main/scripts/claude-wrapper.sh"
WRAPPER_DEST_DIR="$HOME/.local/bin"
WRAPPER_DEST="$WRAPPER_DEST_DIR/claude"
WRAPPER_REAL_LINK="$WRAPPER_DEST_DIR/claude-real"

mkdir -p "$WRAPPER_DEST_DIR"

locate_real_claude() {
  if [ -n "${CLAUDE_REAL_BIN:-}" ] && [ -x "$CLAUDE_REAL_BIN" ]; then
    printf '%s\n' "$CLAUDE_REAL_BIN"
    return 0
  fi
  local IFS=:
  local dir cand real
  for dir in $PATH; do
    [ -z "$dir" ] && continue
    cand="$dir/claude"
    [ -x "$cand" ] || continue
    real=$(readlink -f "$cand" 2>/dev/null || readlink "$cand" 2>/dev/null || printf '%s\n' "$cand")
    case "$real" in
      "$WRAPPER_DEST"|"$WRAPPER_REAL_LINK") continue ;;
    esac
    printf '%s\n' "$cand"
    return 0
  done
  for cand in /opt/homebrew/bin/claude /usr/local/bin/claude "$HOME/.local/share/claude/versions"/*/claude "$HOME/.claude/local/claude"; do
    [ -x "$cand" ] || continue
    printf '%s\n' "$cand"
    return 0
  done
  return 1
}

REAL_CLAUDE=$(locate_real_claude || true)
if [ -n "$REAL_CLAUDE" ]; then
  ln -sfn "$REAL_CLAUDE" "$WRAPPER_REAL_LINK"
  ok "claude-real -> $REAL_CLAUDE"
else
  warn "could not locate the real 'claude' binary"
  note "Install Claude Code from https://claude.com/claude-code, then re-run this installer"
fi

WRAPPER_LOCAL_SRC="$(dirname "$0")/scripts/claude-wrapper.sh"
if [ -f "$WRAPPER_LOCAL_SRC" ]; then
  cp "$WRAPPER_LOCAL_SRC" "$WRAPPER_DEST"
  ok "copied claude-wrapper.sh from local checkout"
elif command -v curl >/dev/null 2>&1; then
  if curl -fsSL "$WRAPPER_SRC_URL" -o "$WRAPPER_DEST.tmp" 2>/dev/null; then
    mv "$WRAPPER_DEST.tmp" "$WRAPPER_DEST"
    ok "downloaded claude-wrapper.sh"
  else
    rm -f "$WRAPPER_DEST.tmp"
    warn "could not download wrapper from $WRAPPER_SRC_URL"
  fi
else
  warn "curl not available; skipping wrapper install"
fi

if [ -f "$WRAPPER_DEST" ]; then
  chmod +x "$WRAPPER_DEST"
  ok "claude wrapper: $WRAPPER_DEST"
  note "Every 'claude ...' (raw, wrapped, scripted) now goes through this wrapper."
fi

SHELL_RC=""
case "$SHELL" in
  */zsh)  SHELL_RC="$HOME/.zshrc" ;;
  */bash)
    if [ -f "$HOME/.bash_profile" ] && [ "$(uname)" = "Darwin" ]; then
      SHELL_RC="$HOME/.bash_profile"
    else
      SHELL_RC="$HOME/.bashrc"
    fi
    ;;
esac

if [ -n "$SHELL_RC" ]; then
  if [ -f "$SHELL_RC" ]; then
    "$PY_BIN" -c "
import re, sys
p = sys.argv[1]
with open(p) as f: s = f.read()
s = re.sub(r'\n?# >>> opencode-anthropic-auth-wrapper >>>.*?# <<< opencode-anthropic-auth-wrapper <<<\n?', '', s, flags=re.DOTALL)
s = re.sub(r'\n?# >>> opencode-anthropic-auth-path >>>.*?# <<< opencode-anthropic-auth-path <<<\n?', '', s, flags=re.DOTALL)
with open(p, 'w') as f: f.write(s)
" "$SHELL_RC"
  fi

  cat >> "$SHELL_RC" <<'SHELL_SNIPPET'

# >>> opencode-anthropic-auth-path >>>
# Auto-generated by opencode-anthropic-auth installer. Do not edit manually.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< opencode-anthropic-auth-path <<<

# >>> opencode-anthropic-auth-wrapper >>>
# Auto-generated by opencode-anthropic-auth installer. Do not edit manually.
claude() {
    "$HOME/.local/bin/claude" "$@"
    return $?
}
# <<< opencode-anthropic-auth-wrapper <<<
SHELL_SNIPPET

  ok "shell hooks: $SHELL_RC"
  note "Adds ~/.local/bin to PATH and makes 'claude' resolve to the wrapper."
  note "Reload shell or run: source $SHELL_RC"
else
  warn "Unsupported shell ($SHELL) — shell hooks not installed"
  note "Add ~/.local/bin to your PATH manually."
fi

step "Installing Keychain -> OpenCode sync helper"

SYNC_SRC_URL="https://raw.githubusercontent.com/iamtheavoc1/opencode-anthropic-auth-fix/main/scripts/sync-claude-to-opencode.sh"
SYNC_DEST_DIR="$HOME/.local/bin"
SYNC_DEST="$SYNC_DEST_DIR/sync-claude-to-opencode.sh"
SYNC_LINK="$SYNC_DEST_DIR/claude-sync"

mkdir -p "$SYNC_DEST_DIR"

SYNC_LOCAL_SRC="$(dirname "$0")/scripts/sync-claude-to-opencode.sh"
if [ -f "$SYNC_LOCAL_SRC" ]; then
  cp "$SYNC_LOCAL_SRC" "$SYNC_DEST"
  ok "copied sync-claude-to-opencode.sh from local checkout"
elif command -v curl >/dev/null 2>&1; then
  if curl -fsSL "$SYNC_SRC_URL" -o "$SYNC_DEST.tmp" 2>/dev/null; then
    mv "$SYNC_DEST.tmp" "$SYNC_DEST"
    ok "downloaded sync-claude-to-opencode.sh"
  else
    rm -f "$SYNC_DEST.tmp"
    warn "could not download sync script from $SYNC_SRC_URL"
  fi
else
  warn "curl not available; skipping sync script install"
fi

if [ -f "$SYNC_DEST" ]; then
  chmod +x "$SYNC_DEST"
  ln -sf "$SYNC_DEST" "$SYNC_LINK"
  ok "sync helper: $SYNC_DEST"
  note "Run 'claude-sync' any time to mirror fresh Keychain creds into OpenCode"
  note "Run 'claude-sync --status' to check upstream token validity"
fi

step "Installing Opus 4.7 thinking helper"

THINK_SRC_URL="https://raw.githubusercontent.com/iamtheavoc1/opencode-anthropic-auth-fix/main/scripts/enable-opus-4-7-thinking.sh"
THINK_DEST="$HOME/.local/bin/enable-opus-4-7-thinking.sh"

THINK_LOCAL_SRC="$(dirname "$0")/scripts/enable-opus-4-7-thinking.sh"
if [ -f "$THINK_LOCAL_SRC" ]; then
  cp "$THINK_LOCAL_SRC" "$THINK_DEST"
  ok "copied enable-opus-4-7-thinking.sh from local checkout"
elif command -v curl >/dev/null 2>&1; then
  if curl -fsSL "$THINK_SRC_URL" -o "$THINK_DEST.tmp" 2>/dev/null; then
    mv "$THINK_DEST.tmp" "$THINK_DEST"
    ok "downloaded enable-opus-4-7-thinking.sh"
  else
    rm -f "$THINK_DEST.tmp"
    warn "could not download thinking helper from $THINK_SRC_URL"
  fi
fi

if [ -f "$THINK_DEST" ]; then
  chmod +x "$THINK_DEST"
  note "Opt-in to Opus 4.7 thinking (adaptive + display:summarized + 200k context):"
  note "  $THINK_DEST"
  note "  Run with --dry-run first, --revert to undo."
fi

step "Done"

cat <<EOF

  Plugin:  $REPO_ENTRY_DIR
  Config:  $CONFIG_PATH
  Mode:    $MODE
  Install: $INSTALL_MODE

$(if [ "$MODE" = "vps-offload" ]; then cat <<MODE_EOF
  VPS:     canonical refresh runs on your Tailscale VPS
  Pull:    on-demand via $REPO_ENTRY_DIR/pull-from-vps.sh
MODE_EOF
elif [ "$INSTALL_MODE" = "manual" ]; then cat <<MODE_EOF
  Manual:  no local daemon installed; use doctor.mjs when you want a one-shot refresh
MODE_EOF
else cat <<MODE_EOF
  Daemon:  refreshes tokens every 45min (check $REPO_ENTRY_DIR/refresh.log)
MODE_EOF
fi)

  Restart OpenCode to pick up the new plugin:

    pkill -x opencode 2>/dev/null
    opencode

  Test:

    opencode run "say hi" --model anthropic/claude-sonnet-4-6

  Re-run this installer any time to update or re-apply.
  If Anthropic revokes the refresh chain, one new 'claude auth login' is still required.

EOF
