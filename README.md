# opencode-claude-proxy

The repository name is historical. The current fix does **not** run a local Claude proxy — it installs Anthropic auth wiring plus a self-healing token recovery patch on top of `@ex-machina/opencode-anthropic-auth`.

One-command fix so [OpenCode](https://opencode.ai) bills Anthropic calls against your Claude Pro/Max subscription instead of the misleading `"You're out of extra usage"` error.

```bash
curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-anthropic-auth-fix/main/fix-opencode.sh | bash
```

**Do you need `claude auth login` first?**
- **Yes, once** — if you've never logged in before. Run `claude auth login`, complete the browser flow, then run the curl command above.
- **No** — if you've logged in before (even on another machine session, even if `claude auth status` now shows `loggedIn: false`). The installer picks up whatever valid OAuth tokens exist in `~/.local/share/opencode/auth.json` and takes it from there.

After that one-time setup, you have two supported modes:

- **Mac-only mode** (default): `fix-opencode.sh` installs the self-healing plugin, a local refresh daemon, and a `claude()` wrapper.
- **VPS-offload mode** (recommended if your Mac sleeps a lot): a Linux VPS on your Tailscale tailnet becomes the only canonical refresher, and your Mac becomes a pure consumer that pulls fresh tokens on demand.

The important Claude CLI auth detail is now known and baked into the wrapper: **`CLAUDE_CODE_OAUTH_TOKEN` alone is not enough**. Claude CLI needs all three env vars together:

- `CLAUDE_CODE_OAUTH_TOKEN`
- `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`
- `CLAUDE_CODE_OAUTH_SCOPES`

If any of the three is missing, Claude returns `401 Invalid authentication credentials` even when the access token itself looks valid.

After the curl command runs, reload your shell and restart OpenCode:

```bash
source ~/.zshrc   # or ~/.bashrc — activates the claude() wrapper
pkill -x opencode 2>/dev/null; opencode
```

## VPS-offload mode

If your real requirement is **"keep auth alive while my Mac is offline/asleep, and do not run refresh work on the Mac during sleep"**, use VPS-offload mode.

1. Provision the VPS daemon from your Mac:

```bash
bash ./install-vps-daemon.sh <ssh-host>
```

That script:

- installs `age`, `jq`, `node`, and `tailscale` on the VPS if needed
- creates the `ocauth` service account and `/opt/ocauth/`
- deploys the refresh daemon and token server as systemd units
- migrates your current local OpenCode OAuth pair to the VPS
- writes a local `~/.local/share/opencode-anthropic-auth/.vps-config`

2. Re-run the main installer in VPS mode:

```bash
OCAUTH_VPS_HOST=<tailscale-hostname> \
OCAUTH_TS_IP=<tailscale-ip> \
OCAUTH_BEARER=<bearer> \
bash ./fix-opencode.sh
```

Or, if `install-vps-daemon.sh` already wrote `.vps-config`, just run `fix-opencode.sh` again and it auto-detects VPS mode.

In VPS-offload mode:

- the Mac does **not** run `caffeinate`
- the Mac does **not** keep a launchd/cron refresh loop alive
- the VPS refreshes every 30 minutes via systemd timer
- the `claude()` wrapper pulls from the VPS before each invocation and retries once after a 401
- public internet access stays closed; the token server binds only to the Tailscale address

## The root cause — what's actually broken

Writing this down because I wasted hours on the wrong theory and every plugin and blog post on the internet gets it wrong.

**Anthropic's `/v1/messages` API validates the `system[]` array for OAuth requests.** For requests billed against the Claude Code subscription pool, `system[]` is allowed to contain exactly one thing: the identity block (`"You are a Claude agent, built on Anthropic's Claude Agent SDK."`). Any additional entries — OpenCode's agent prompts, OhMyOpenCode's Sisyphus configuration, tool descriptions, workspace memory blocks, cache control markers — trigger an HTTP 400 whose error body is:

```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "You're out of extra usage. Add more at claude.ai/settings/usage and keep going."
  }
}
```

**That error message is completely misleading.** The "extra usage" pool isn't the problem. Your subscription pool has plenty of headroom. What Anthropic is actually saying is "your `system[]` is not an attributable Claude Code session", and the fact that it surfaces as an extra-usage error is a billing-classification quirk.

What's *not* the problem (despite every other plugin patching these):

- `x-anthropic-billing-header` values (`cc_version=X.Y.Z.hash; cc_entrypoint=cli; cch=hash`) — Anthropic computes `cch` as a per-request hash of your prompt, but any value works here as long as the header is present.
- The user-agent string (`claude-cli/2.1.100 (external, cli)`)
- The `anthropic-beta` flag list
- The x-stainless-* SDK headers
- The OAuth scopes
- Using `CLAUDE_CODE_OAUTH_TOKEN` vs keychain session tokens

What *is* the problem: `system[]` must have exactly the identity block and nothing else. Everything else belongs in the user message.

## How the fix works

`fix-opencode.sh` installs [`@ex-machina/opencode-anthropic-auth`](https://www.npmjs.com/package/@ex-machina/opencode-anthropic-auth), which has a `rewriteRequestBody()` function that transparently relocates every non-identity system block to `messages[0].content` before forwarding to Anthropic:

```js
// From the plugin's transform.js — this is the entire fix
// Anthropic's API validates system[] content for OAuth requests.
// Third-party system prompts trigger a 400 rejection when they
// appear in system[]. Keep only the identity block in system[]
// and prepend everything else to the first user message.
```

So OpenCode keeps building its multi-block system prompts the normal way, the plugin rewrites the body on the fetch boundary, and Anthropic sees a valid shape. Your OpenCode agents and OMO orchestrators work unchanged.

## What the installer does

1. Verifies `claude` CLI, `npm`, `git`, `python3`, and (optionally) `opencode` are reachable. Falls back to common install locations (`~/.bun/bin`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`) so it works even when run via `curl | bash` in a subshell that doesn't inherit your interactive PATH.
2. Downloads `@ex-machina/opencode-anthropic-auth` via `npm pack` (no global install, no root, no side effects on your npm prefix).
3. Extracts it to `~/.local/share/opencode-anthropic-auth/`.
4. Patches the installed plugin so auth is less brittle:
   - refreshes within 60 seconds of expiry instead of waiting until the token is already dead
   - if OpenCode's refresh token is stale but your local `claude` CLI is still logged in, locally borrows a fresh Claude CLI bearer token and keeps the request flowing
5. Backs up `~/.config/opencode/opencode.json` to `opencode.json.bak.<timestamp>`.
6. Rewrites the config to:
   - register the plugin via `file://` reference
   - strip `opencode-claude-bridge` and `opencode-claude-code-plugin` from the `plugin` list (both cause the extra-usage error)
   - strip `claude-proxy` and `claude-code` provider entries (both superseded)
   - set the default model to `anthropic/claude-sonnet-4-6` if none is set, or if the existing default pointed at one of the removed providers

7. Installs token freshness automation:
    - **Mac-only mode** (default):
      - macOS: LaunchAgent at `~/Library/LaunchAgents/com.opencode-anthropic-auth.refresh.plist`
      - Linux: cron job
      - Runs every 45 minutes, refreshes via OAuth when the token has < 1 hour remaining
      - macOS path uses `caffeinate` + a wake-oriented LaunchAgent because the machine itself is the refresher
    - **VPS-offload mode** (`OCAUTH_VPS_HOST` set, or `.vps-config` already present):
      - skips the local daemon entirely
      - unloads the legacy LaunchAgent if one exists
      - installs `pull-from-vps.sh`, which pulls a fresh OAuth pair over Tailscale on demand
      - expects a remote systemd timer to refresh every 30 minutes on the VPS

8. Installs a `claude()` shell wrapper function in your shell RC file (`.zshrc` or `.bashrc`):
    - Reads the current OAuth access token, refresh token, and expiry from `~/.local/share/opencode/auth.json`
    - Sets `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, and `CLAUDE_CODE_OAUTH_SCOPES` together
    - In VPS mode, pulls from the VPS before invocation and retries once after a 401
    - Works even when `claude auth status` shows `loggedIn: false`
    - Degrades gracefully: if auth.json is missing, runs `claude` normally without the env vars

Existing keys, other plugins, and other providers are preserved. The rewrite is JSON-safe (done in Python, not sed).

## Requirements

| Tool | Why | Install |
| --- | --- | --- |
| [**Claude CLI**](https://docs.claude.com/en/docs/claude-code/overview) | Provides the OAuth session the installer bootstraps from. Run `claude auth login` once if you've never logged in before. | [Install docs](https://docs.claude.com/en/docs/claude-code/overview) |
| **Claude Pro or Max subscription** | Without one there's nothing to bill against. | [claude.ai/upgrade](https://claude.ai/upgrade) |
| [**OpenCode**](https://opencode.ai) | The thing we're patching. | Follow the install instructions at opencode.ai. |
| **Node.js** | Runs the refresh daemon. Also provides npm. | [nodejs.org](https://nodejs.org/) |
| **jq** | Required for VPS-offload token pulls and payload validation. | Your package manager / `brew install jq` |
| **python3** | Rewrites `opencode.json` safely. | Preinstalled on macOS and most Linux distros. |
| **git** | Used by the installer's sanity checks. | Xcode Command Line Tools / your package manager. |

### Extra requirements for VPS-offload mode

- A Linux VPS with `sudo`
- SSH access to that VPS from your Mac
- Tailscale on both machines, in the same tailnet

## Verification

Verified end-to-end on a real machine — **not** an isolated probe — by running the exact path that was consistently failing:

```bash
opencode run "say exactly: FIXED_FOR_REAL" --model anthropic/claude-sonnet-4-6
```

through OhMyOpenCode's **Sisyphus (Ultraworker)** agent orchestrator (which attaches a large multi-block system prompt), the model returned `FIXED_FOR_REAL`, the bridge debug log showed **two HTTP 200 responses** from Anthropic, and the TUI had zero errors. Before the fix, the same command produced `"You're out of extra usage"` on the first turn every single time.

## Troubleshooting

**Still seeing `"out of extra usage"` after running the installer.**
OpenCode caches plugins in memory — the running TUI didn't reload. Kill it and relaunch:

```bash
pkill -x opencode 2>/dev/null; opencode
```

**Getting `Token refresh failed: 400 — {"error":"invalid_grant", ...}`.**
That means OpenCode's stored refresh token is stale. The installer-patched plugin now tries to self-heal by borrowing a fresh bearer token from your local `claude` CLI login. If `claude` is still logged in, the next request should recover automatically.

If you instead see `invalid authentication credentials`, there are two common cases:

- **Mac-only mode**: the cached access token is no longer accepted even though the stored expiry timestamp has not elapsed yet. The patched plugin force-refreshes immediately and retries.
- **VPS-offload mode**: the Mac is holding an older token pair than the VPS. Force a pull, then retry:

```bash
~/.local/share/opencode-anthropic-auth/pull-from-vps.sh
claude --print "say exactly: AUTH_OK"
```

The installer wrapper now does this automatically in VPS mode before invocation and once more after a 401.

With either refresh path installed, this should be rare. In Mac-only mode the local daemon refreshes every 45 minutes; in VPS-offload mode the VPS timer refreshes every 30 minutes. The plugin retries on failures. Check the log if things seem off:

```bash
cat ~/.local/share/opencode-anthropic-auth/refresh.log
```

If the daemon log shows `FAIL` entries, the refresh token itself may have expired (e.g. machine was off for days). One `claude login` resets the chain:

```bash
claude login
```

If OpenCode keeps holding onto a bad auth record after that, clear just the Anthropic entry and let the plugin rebuild from the next request:

```bash
python3 -c 'import json,os; p=os.path.expanduser("~/.local/share/opencode/auth.json"); a=json.load(open(p)); a.pop("anthropic", None); json.dump(a, open(p, "w"), indent=2)'
```

**Machine was off (or hibernating) for a very long time and now nothing works.**

If you are in **VPS-offload mode**, this is exactly what the VPS is for — the Mac can be completely offline and the token chain still survives because the VPS is doing the refresh work.

If you are in **Mac-only mode**, the daemon only runs while the machine is awake. Anthropic's OAuth refresh tokens expire after ~1-2 hours of inactivity, so the unavoidable failure mode is still the Mac sleeping with the lid **closed** for too long.

Recovery is one command:

```bash
~/.local/share/opencode-anthropic-auth/recover.sh
```

It opens the Anthropic login page once, writes the new token into your opencode auth store, and re-establishes the full paired token. The `claude()` shell wrapper detects auth failures automatically and prints a banner pointing you at `recover.sh` — you don't need to diagnose anything.

**Daemon not running?**
Check with `launchctl list | grep opencode-anthropic-auth`. If missing, re-run the installer.

**Running the installer overwrote my default model.**
It only replaces the default if it was unset or pointed at a removed provider (`claude-code/*` or `claude-proxy/*`). Your backup is at `~/.config/opencode/opencode.json.bak.<timestamp>` — copy the `"model"` field back if you need to.

**The plugin got an npm update, how do I reapply?**
Re-run the same curl command. It's idempotent and picks up the latest version on each run.

## Keeping the Token Fresh

There are now two token-freshness architectures.

### 1. Mac-only mode

- Local LaunchAgent/cron refresh every 45 minutes
- Plugin refreshes reactively on request failures
- Works well while the machine is awake
- Still subject to the lid-closed sleep limitation on macOS hardware

### 2. VPS-offload mode

- VPS systemd timer refreshes every 30 minutes
- Token server binds only to the Tailscale address
- Mac runs no refresh daemon while asleep
- Mac pulls on demand through `pull-from-vps.sh`

If your real goal is "offline-proof and no refresh work during Mac sleep", use VPS-offload mode.

## What if the token dies?

In **Mac-only mode**, there is exactly one unavoidable failure mode: the Mac asleep with lid CLOSED for more than ~2 hours. macOS hardware enforces sleep when the lid closes, so no scheduled job can run, so the refresh token times out.

In **VPS-offload mode**, that failure mode moves off the Mac. As long as the VPS is up and connected to Tailscale, the token chain stays alive even if the Mac is shut down.

Recovery is **one command**:

```bash
~/.local/share/opencode-anthropic-auth/recover.sh
```

It opens the Anthropic login page once, writes the new token into your
opencode auth store, and re-establishes the full paired token. After that,
the 45-minute refresh loop takes over again.

The `claude()` shell wrapper detects this failure automatically and prints a
banner telling you to run `recover.sh` — you don't need to diagnose anything.

## Token lifecycle

Two layers keep your tokens alive:

**Mac-only daemon** (proactive — runs every 45 minutes):

1. Checks the `expires` timestamp in `~/.local/share/opencode/auth.json`.
2. If < 1 hour remaining, POSTs to `https://platform.claude.com/v1/oauth/token` with `grant_type=refresh_token`.
3. Writes the fresh access token, refresh token, and expiry back to `auth.json`.
4. If OAuth refresh fails, falls back to capturing a fresh bearer from Claude CLI via loopback proxy.
5. Logs every action to `~/.local/share/opencode-anthropic-auth/refresh.log`.

**Plugin** (reactive — runs on every API call):

1. Checks the `expires` timestamp before each `/v1/messages` call.
2. If within ~1 minute of expiry, refreshes via OAuth or Claude CLI fallback (same logic as the daemon).
3. If a request returns 401/403/`invalid authentication credentials`, force-refreshes and retries once.

**VPS-offload daemon** (proactive — runs every 30 minutes on the VPS):

1. Decrypts the stored OAuth token on the VPS.
2. Refreshes it against `https://platform.claude.com/v1/oauth/token` when < 1 hour remains.
3. Re-encrypts and stores the rotated access+refresh pair.
4. Serves the current pair only over a bearer-protected Tailscale-bound HTTP endpoint.

Under normal use, one of these proactive daemons handles freshness and the plugin remains the safety net. The wrapper is the final layer for on-demand `claude` invocations.

**Shell wrapper** (on-demand — every `claude` invocation):

1. Reads the current access token, refresh token, and expiry from `~/.local/share/opencode/auth.json`.
2. In VPS mode, pulls a fresh pair from the VPS before invocation.
3. Sets `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`, and `CLAUDE_CODE_OAUTH_SCOPES` together.
4. Calls the real `claude` binary.
5. If Claude still returns a 401, pulls again and retries once.

## Claude CLI wrapper

The installer adds a `claude()` function to your shell RC file (`.zshrc` on zsh, `.bashrc`/`.bash_profile` on bash). It wraps the real `claude` binary to automatically supply the OAuth material from `auth.json`:

```bash
# Added to your shell RC by the installer
claude() {
    local __oaa_auth __oaa_access __oaa_refresh
    local __oaa_pull="$HOME/.local/share/opencode-anthropic-auth/pull-from-vps.sh"
    [ -x "$__oaa_pull" ] && "$__oaa_pull" >/dev/null 2>&1 || true
    __oaa_auth=$(python3 -c "
import json, os, sys
try:
    p = os.path.expanduser('~/.local/share/opencode/auth.json')
    a = json.load(open(p)).get('anthropic', {})
    print(a.get('access', ''))
    print(a.get('refresh', ''))
except: sys.exit(1)
" 2>/dev/null)
    __oaa_access=$(printf '%s\n' "$__oaa_auth" | sed -n '1p')
    __oaa_refresh=$(printf '%s\n' "$__oaa_auth" | sed -n '2p')
    if [ -n "$__oaa_access" ] && [ -n "$__oaa_refresh" ]; then
        CLAUDE_CODE_OAUTH_TOKEN="$__oaa_access" \
        CLAUDE_CODE_OAUTH_REFRESH_TOKEN="$__oaa_refresh" \
        CLAUDE_CODE_OAUTH_SCOPES="user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload org:create_api_key" \
        command claude "$@"
    else
        command claude "$@"
    fi
}
```

This means `claude --print "hello"` works even when `claude auth status` reports `loggedIn: false` — as long as `auth.json` has a valid OAuth pair.

**Verify it's active:**
```bash
type claude   # Should print: claude is a function
```

**If using an unsupported shell** (fish, etc.), add the function manually to your shell config, or export all three vars directly:
```bash
export CLAUDE_CODE_OAUTH_TOKEN=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.local/share/opencode/auth.json')))['anthropic']['access'])")
export CLAUDE_CODE_OAUTH_REFRESH_TOKEN=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.local/share/opencode/auth.json')))['anthropic']['refresh'])")
export CLAUDE_CODE_OAUTH_SCOPES='user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload org:create_api_key'
```

The wrapper is injected with idempotent marker comments — re-running the installer updates it in-place without duplicating it.

## Scripts reference

This repo ships three installers/helpers and installs four more scripts into your home directory. Each one has one job. Here is the full map.

### Shipped in this repo

| Script | Location in repo | Run when | What it does |
| --- | --- | --- | --- |
| `fix-opencode.sh` | repo root | Once on each Mac (client) | Installs the `@ex-machina/opencode-anthropic-auth` plugin, patches it for self-healing refresh, rewrites `opencode.json`, installs a Mac-only refresh daemon (or the VPS pull helper in VPS-offload mode), installs the **PATH-level `claude` wrapper** at `~/.local/bin/claude` together with a `claude-real` symlink to the underlying Claude Code binary, and drops `sync-claude-to-opencode.sh` into `~/.local/bin`. Adds `~/.local/bin` to your PATH via your shell rc. Idempotent — re-run to update. |
| `install-vps-daemon.sh <ssh-host>` | repo root | Once per VPS | Bootstraps a Linux VPS as the canonical token refresher. Installs `age`/`jq`/`node`/`tailscale`, creates the `ocauth` service account, deploys systemd `ocauth-refresh.service` + `ocauth-refresh.timer` + `ocauth-server.service`, migrates your current local OAuth pair into `/opt/ocauth/token.age`, and writes `~/.local/share/opencode-anthropic-auth/.vps-config` on your Mac (including `OCAUTH_SSH_HOST` so the Mac can pull tokens over plain SSH even when Tailscale is down). |
| `scripts/claude-wrapper.sh` | repo `scripts/` | Installed as `~/.local/bin/claude` | The PATH-level wrapper that sits in front of the real Claude Code binary. Every `claude` invocation — interactive, non-interactive, scripted, or from `command claude` — goes through it. It: auto-discovers the real binary (or uses `$CLAUDE_REAL_BIN` / `~/.local/bin/claude-real`), runs `doctor --fix` to heal a stale `auth.json`, injects `CLAUDE_CODE_OAUTH_TOKEN`/`_REFRESH_TOKEN`/`_SCOPES` from `auth.json`, transparently pulls from the VPS if needed, and on a live 401 performs one pull+refresh retry before giving up with a clear message. `claude auth`, `claude setup-token`, and `claude mcp` bypass the injection (they manage their own auth flow). |
| `scripts/sync-claude-to-opencode.sh` | repo `scripts/` | On demand on your Mac | Reads the **fresh** Claude CLI OAuth pair from the macOS Keychain (`Claude Code-credentials`) and mirrors it into `~/.local/share/opencode/auth.json`. Before writing, it calls `api.anthropic.com/api/oauth/usage` to verify the token is actually accepted upstream (expiry timestamps alone are not enough — Anthropic can revoke a token while it still looks valid locally). If the local token is expiring within 10 minutes (`PROACTIVE_REFRESH_MS`) or is invalid, it auto-refreshes via `claude` CLI; if refresh fails, it tells you to run `claude auth login`. Supports `--status` (reads `auth.json` first, Keychain second — so it reflects the token you actually use), `--version`, and `--help`. |
| `scripts/enable-opus-4-7-thinking.sh` | repo `scripts/` | Once, opt-in, on each Mac | Patches `opencode.json` so Claude Opus 4.7 actually **surfaces its extended thinking** in the TUI. Adds `options.thinking = { type: "adaptive", display: "summarized" }` and `options.effort = "xhigh"` under `claude-opus-4-7`, and rewrites the models.dev capability cache (`~/.cache/opencode/models.json`) so the context meter shows the correct 200k default instead of the 1M extended-beta number. Safe to re-run. Supports `--dry-run` and `--revert` (restores from `*.bak-pre-opus47-thinking` backups). See "Enable thinking on Opus 4.7" below for why all three layers are needed. |

### Installed into your home directory

| Installed path | Source | Run when | What it does |
| --- | --- | --- | --- |
| `~/.local/share/opencode-anthropic-auth/dist/` | `npm pack @ex-machina/opencode-anthropic-auth`, patched | Loaded on every OpenCode request | The actual plugin. Rewrites `system[]` so Anthropic accepts OAuth-billed requests, and self-heals by force-refreshing on 401/403/`invalid authentication credentials`. |
| `~/.local/share/opencode-anthropic-auth/pull-from-vps.sh` | emitted by `fix-opencode.sh` (VPS-offload mode only) | Automatically by the `claude` wrapper, or manually | Pulls a fresh OAuth pair from the VPS and merges it into `auth.json`. Tries **SSH first, then fqdn, then tailscale IP**, so Tailscale being down no longer blocks the VPS path as long as plain SSH to the VPS works. Reads `.vps-config` for `OCAUTH_HOST`, `OCAUTH_TS_IP`, `OCAUTH_PORT`, `OCAUTH_BEARER`, and `OCAUTH_SSH_HOST`. |
| `~/.local/share/opencode-anthropic-auth/recover.sh` | shipped in the npm package | When the `claude()` wrapper prints a recovery banner | Opens the Anthropic login page, writes the new token into OpenCode's auth store, and re-establishes the paired token. |
| `~/.local/share/opencode-anthropic-auth/reset.sh` | shipped in the npm package | Manual — last resort | Clears OpenCode's Anthropic auth entry so the plugin can rebuild it from scratch on the next request. |
| `~/.local/share/opencode-anthropic-auth/.vps-config` | `install-vps-daemon.sh` | Read by `pull-from-vps.sh` | Tailscale host/IP, bearer token, and `OCAUTH_SSH_HOST`. Mode `600`. |
| `~/.local/share/opencode-anthropic-auth/refresh.log` | daemons + helpers | Append-only | Single source of truth for "what did auth do and when". Inspect this before assuming anything. |
| `~/.local/bin/claude` | copied by `fix-opencode.sh` from `scripts/claude-wrapper.sh` | Every `claude …` invocation | The PATH-level wrapper. See `scripts/claude-wrapper.sh` above. Because `~/.local/bin` is prepended to your PATH, this is what `claude`, `command claude`, and every scripted caller resolve to. |
| `~/.local/bin/claude-real` | symlink created by `fix-opencode.sh` | Target of the wrapper | Points at the real Claude Code binary the wrapper discovered (Homebrew, `~/.claude/local/claude`, etc.). Only edit/override via `CLAUDE_REAL_BIN`. |
| `~/.local/bin/sync-claude-to-opencode.sh` | copied by `fix-opencode.sh` | On demand | See `scripts/sync-claude-to-opencode.sh` above. |
| `~/.local/bin/claude-sync` | symlink to the above | Convenience shortcut | `claude-sync` = run sync, `claude-sync --status` = show state (reports `auth.json` first, Keychain second). |
| `~/.local/bin/enable-opus-4-7-thinking.sh` | copied by `fix-opencode.sh` | Once, opt-in | See `scripts/enable-opus-4-7-thinking.sh` above. |
| `claude()` shell function in `~/.zshrc` or `~/.bashrc` | injected by `fix-opencode.sh` | Every `claude …` invocation from an interactive shell | A tiny delegator that forwards to `~/.local/bin/claude`. Exists purely so old shells that cached `claude` to a function pick up the wrapper on the next reload. The real logic lives in `~/.local/bin/claude`. |
| `# >>> opencode-anthropic-auth-path` block in your shell rc | injected by `fix-opencode.sh` | Every new shell | Idempotently prepends `~/.local/bin` to `PATH` so the wrapper wins over any Homebrew/cask install of `claude`. |

### When to reach for which

- **Something is broken, I don't know what** → `cat ~/.local/share/opencode-anthropic-auth/refresh.log` first, then `claude-sync --status`.
- **`opencode` says "out of extra usage"** → Plugin didn't load. `pkill -x opencode; opencode`. If it persists, re-run `fix-opencode.sh`.
- **`claude` says `Invalid authentication credentials`** → The wrapper will already have tried one pull+refresh retry. If you still see this, run `claude auth login` once, then `claude-sync` to mirror the fresh creds into OpenCode. If you kept seeing it *before* this version of the installer, it was almost certainly because `command claude` was bypassing the old shell-function-only wrapper; that's fixed now because `claude` is a real script on `PATH`.
- **Mac was off/asleep for hours and nothing works** → In VPS-offload mode: `~/.local/share/opencode-anthropic-auth/pull-from-vps.sh`. In Mac-only mode: `~/.local/share/opencode-anthropic-auth/recover.sh`.
- **I just want to see how much of my quota I've used** → `claude-sync --status`.
- **Tailscale is off and I still want the VPS pull to work** → Make sure `OCAUTH_SSH_HOST` is set in `.vps-config` (the installer now does this). `pull-from-vps.sh` tries SSH **first**, so Tailscale being down is a non-event.

## Enable thinking on Opus 4.7

Claude Opus 4.7 supports extended thinking, but you will **not see it** in OpenCode out of the box. There are three separate layers that all have to be in the right state, and the default install only does one of them.

### The three layers

| Layer | What it controls | Default state |
| --- | --- | --- |
| **1. Request body**: `thinking: { type: "adaptive", display: "summarized" }` | Whether Claude thinks at all, and whether the thinking text is returned or only its encrypted `signature`. On Opus 4.7, `display` silently defaults to `"omitted"` — you get empty thinking blocks unless you explicitly opt in. | **Not set.** `effort` alone is not enough; `effort` without `thinking: adaptive` is ignored on 4.7. |
| **2. Beta header**: `anthropic-beta: oauth-2025-04-20,interleaved-thinking-2025-05-14` | Authorizes the OAuth subscription path and enables interleaved thinking (thinking between tool calls). | **Already sent** by `@ex-machina/opencode-anthropic-auth` after `fix-opencode.sh`. |
| **3. Context cache**: `~/.cache/opencode/models.json` entry for `claude-opus-4-7` | What the OpenCode TUI's context meter uses as the denominator. | Ships as **1M** (extended beta tier). Subscription OAuth accounts are tier-1; the real cap is **200k**. Mismatch makes the "% context used" meter lie. |

### The fix

`scripts/enable-opus-4-7-thinking.sh` does layers 1 and 3 in one command (layer 2 is already covered by the main installer):

```bash
~/.local/bin/enable-opus-4-7-thinking.sh --dry-run   # preview
~/.local/bin/enable-opus-4-7-thinking.sh             # apply
pkill -x opencode 2>/dev/null; opencode              # reload
```

After apply, your `claude-opus-4-7` entry looks like:

```json
"claude-opus-4-7": {
  "limit": { "context": 200000, "output": 128000 },
  "options": {
    "effort": "xhigh",
    "thinking": { "type": "adaptive", "display": "summarized" }
  }
}
```

### Why each field is the way it is

- **`type: "adaptive"`** — Opus 4.7 **rejects** the old `type: "enabled", budget_tokens: N` shape with a 400. Adaptive is the only supported mode on 4.7, and it's also recommended on 4.6 / Sonnet 4.6.
- **`display: "summarized"`** — On Opus 4.7, `display` silently defaults to `"omitted"`, which means the thinking blocks arrive with empty `thinking` fields. This catches most people. Setting it explicitly restores visible thinking.
- **`effort: "xhigh"`** — Soft guidance on how hard Claude thinks. `xhigh` is specific to Opus 4.7. `max` also exists but is expensive; `high` is the documented default. Only matters when `thinking.type` is `adaptive`.
- **`limit.context: 200000`** — The 1M context tier is gated behind the `context-1m-2025-08-07` beta header, a tier 4+ org, and 2x/1.5x pricing above 200k tokens. None of that applies to Claude Pro/Max subscription OAuth. 200k is your actual ceiling.

### Undo

```bash
~/.local/bin/enable-opus-4-7-thinking.sh --revert
```

Reverts using the `.bak-pre-opus47-thinking` backups written on first apply.

## Credits

The actual fix — the `rewriteRequestBody` logic that relocates non-identity system blocks — is in [`@ex-machina/opencode-anthropic-auth`](https://www.npmjs.com/package/@ex-machina/opencode-anthropic-auth) by [ex-machina-co](https://github.com/ex-machina-co/opencode-anthropic-auth). Huge thanks to [@juliancoy](https://github.com/juliancoy) for figuring out the `system[]` validation and publishing the plugin. This repo is just a one-command installer that wires it into OpenCode's config correctly and rips out the broken legacy plugins.

## License

[MIT](./LICENSE)
