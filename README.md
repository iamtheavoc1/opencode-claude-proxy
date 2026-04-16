# opencode-claude-proxy

The repository name is historical. The current fix does **not** run a local Claude proxy — it installs Anthropic auth wiring plus a self-healing token recovery patch on top of `@ex-machina/opencode-anthropic-auth`.

One-command fix so [OpenCode](https://opencode.ai) bills Anthropic calls against your Claude Pro/Max subscription instead of the misleading `"You're out of extra usage"` error.

```bash
curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-anthropic-auth-fix/main/fix-opencode.sh | bash
```

**Do you need `claude auth login` first?**
- **Yes, once** — if you've never logged in before. Run `claude auth login`, complete the browser flow, then run the curl command above.
- **No** — if you've logged in before (even on another machine session, even if `claude auth status` now shows `loggedIn: false`). The installer picks up whatever valid OAuth tokens exist in `~/.local/share/opencode/auth.json` and takes it from there.

After that one-time setup: **you never touch auth again.** The installer sets up a background daemon (LaunchAgent on macOS, cron on Linux) that proactively refreshes your OAuth tokens every 45 minutes, and a `claude()` shell wrapper that feeds those tokens to the Claude CLI automatically. Each OAuth refresh rotates both the access and refresh tokens, so the chain stays alive indefinitely.

After the curl command runs, reload your shell and restart OpenCode:

```bash
source ~/.zshrc   # or ~/.bashrc — activates the claude() wrapper
pkill -x opencode 2>/dev/null; opencode
```

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

7. Installs a proactive token refresh daemon:
    - macOS: LaunchAgent at `~/Library/LaunchAgents/com.opencode-anthropic-auth.refresh.plist`
    - Linux: cron job (`0 */2 * * *`)
    - Runs every 45 minutes, refreshes via OAuth when the token has < 1 hour remaining
    - LaunchAgent also fires hourly via StartCalendarInterval for dark-wake on lid-open sleep
    - Wrapped in `caffeinate -i` to prevent the Mac from re-sleeping during refresh
    - Each refresh rotates both access and refresh tokens — the chain is self-sustaining
    - Falls back to Claude CLI loopback capture if OAuth refresh fails
    - Logs to `~/.local/share/opencode-anthropic-auth/refresh.log`

8. Installs a `claude()` shell wrapper function in your shell RC file (`.zshrc` or `.bashrc`):
   - Reads the current OAuth access token from `~/.local/share/opencode/auth.json`
   - Sets `CLAUDE_CODE_OAUTH_TOKEN` per-invocation before running the real `claude` binary
   - Works even when `claude auth status` shows `loggedIn: false`
   - Degrades gracefully: if auth.json is missing, runs `claude` normally without the env var

Existing keys, other plugins, and other providers are preserved. The rewrite is JSON-safe (done in Python, not sed).

## Requirements

| Tool | Why | Install |
| --- | --- | --- |
| [**Claude CLI**](https://docs.claude.com/en/docs/claude-code/overview) | Provides the OAuth session the installer bootstraps from. Run `claude auth login` once if you've never logged in before. | [Install docs](https://docs.claude.com/en/docs/claude-code/overview) |
| **Claude Pro or Max subscription** | Without one there's nothing to bill against. | [claude.ai/upgrade](https://claude.ai/upgrade) |
| [**OpenCode**](https://opencode.ai) | The thing we're patching. | Follow the install instructions at opencode.ai. |
| **Node.js** | Runs the refresh daemon. Also provides npm. | [nodejs.org](https://nodejs.org/) |
| **python3** | Rewrites `opencode.json` safely. | Preinstalled on macOS and most Linux distros. |
| **git** | Used by the installer's sanity checks. | Xcode Command Line Tools / your package manager. |

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

If you instead see `invalid authentication credentials`, that usually means the cached OpenCode access token is no longer accepted even though its stored expiry timestamp hasn't elapsed yet. The installer-patched plugin now force-refreshes the OAuth token immediately on that live request failure, writes the rotated token back into OpenCode's auth cache, and retries automatically. If the refresh token itself is stale, it falls back to re-syncing from your local `claude` CLI session.

With the background refresh daemon installed, this should be rare. The daemon refreshes tokens every 45 minutes and the plugin retries on failures. Check the daemon log if things seem off:

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
The daemon refreshes tokens every 45 minutes while the machine is awake. Anthropic's OAuth refresh tokens expire after ~1-2 hours of inactivity, so the 45-minute cadence keeps the chain alive during normal use. The one unavoidable failure mode is the Mac sleeping with the lid **closed** for more than ~2 hours — macOS hardware prevents any scheduled job from running in that state.

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

The installer deploys a LaunchAgent that refreshes your Anthropic OAuth token
proactively. You do NOT need to run `claude auth login` in normal use.

**Cadence**:
- Every 45 minutes when the Mac is awake
- Every hour via dark-wake when the Mac is asleep with lid OPEN
- Immediately on wake, on shell start, and on install

**Why 45 minutes?** Anthropic's OAuth refresh tokens die after 1-2 hours of
inactivity. A 45-minute cadence keeps the token alive with a safe buffer.

## What if the token dies?

There is exactly one unavoidable failure mode: the Mac asleep with lid CLOSED
for more than ~2 hours (e.g., overnight). macOS hardware enforces sleep when
the lid closes, so no scheduled job can run, so the refresh token times out.

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

**Background daemon** (proactive — runs every 45 minutes):

1. Checks the `expires` timestamp in `~/.local/share/opencode/auth.json`.
2. If < 1 hour remaining, POSTs to `https://platform.claude.com/v1/oauth/token` with `grant_type=refresh_token`.
3. Writes the fresh access token, refresh token, and expiry back to `auth.json`.
4. If OAuth refresh fails, falls back to capturing a fresh bearer from Claude CLI via loopback proxy.
5. Logs every action to `~/.local/share/opencode-anthropic-auth/refresh.log`.

**Plugin** (reactive — runs on every API call):

1. Checks the `expires` timestamp before each `/v1/messages` call.
2. If within ~1 minute of expiry, refreshes via OAuth or Claude CLI fallback (same logic as the daemon).
3. If a request returns 401/403/`invalid authentication credentials`, force-refreshes and retries once.

Under normal use the daemon handles everything in the background and you never notice. The plugin's reactive refresh is a safety net in case the daemon misses a cycle. The shell wrapper adds a third layer for on-demand `claude` invocations, keeping the token chain alive indefinitely.

**Shell wrapper** (on-demand — every `claude` invocation):

1. Reads the current access token from `~/.local/share/opencode/auth.json`.
2. Sets `CLAUDE_CODE_OAUTH_TOKEN` for that single invocation.
3. Calls the real `claude` binary. If auth.json is missing or empty, calls `claude` without the env var.

## Claude CLI wrapper

The installer adds a `claude()` function to your shell RC file (`.zshrc` on zsh, `.bashrc`/`.bash_profile` on bash). It wraps the real `claude` binary to automatically supply the OAuth token from `auth.json`:

```bash
# Added to your shell RC by the installer
claude() {
    local __oaa_token
    __oaa_token=$(python3 -c "
import json, os, sys
try:
    p = os.path.expanduser('~/.local/share/opencode/auth.json')
    a = json.load(open(p))
    t = a.get('anthropic', {}).get('access', '')
    if t: print(t, end='')
    else: sys.exit(1)
except: sys.exit(1)
" 2>/dev/null)
    if [ -n "$__oaa_token" ]; then
        CLAUDE_CODE_OAUTH_TOKEN="$__oaa_token" command claude "$@"
    else
        command claude "$@"
    fi
}
```

This means `claude --print "hello"` works even when `claude auth status` reports `loggedIn: false` — as long as `auth.json` has a valid token (which the background daemon keeps fresh).

**Verify it's active:**
```bash
type claude   # Should print: claude is a function
```

**If using an unsupported shell** (fish, etc.), add the function manually to your shell config, or set the env var directly:
```bash
export CLAUDE_CODE_OAUTH_TOKEN=$(python3 -c "import json,os; print(json.load(open(os.path.expanduser('~/.local/share/opencode/auth.json')))['anthropic']['access'])")
```

The wrapper is injected with idempotent marker comments — re-running the installer updates it in-place without duplicating it.

## Credits

The actual fix — the `rewriteRequestBody` logic that relocates non-identity system blocks — is in [`@ex-machina/opencode-anthropic-auth`](https://www.npmjs.com/package/@ex-machina/opencode-anthropic-auth) by [ex-machina-co](https://github.com/ex-machina-co/opencode-anthropic-auth). Huge thanks to [@juliancoy](https://github.com/juliancoy) for figuring out the `system[]` validation and publishing the plugin. This repo is just a one-command installer that wires it into OpenCode's config correctly and rips out the broken legacy plugins.

## License

[MIT](./LICENSE)
