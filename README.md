# opencode-claude-proxy

Run [opencode](https://opencode.ai) against your **Claude Pro / Max**
subscription — no API credits, no separate API key, no fingerprint risk, native
opencode UI, native subagent dispatch, native MCP tools, native streaming,
adaptive thinking blocks.

This repo is a curated installer and service-management layer around
[`@rynfar/meridian`](https://www.npmjs.com/package/@rynfar/meridian) — a local
Anthropic-compatible proxy that authenticates with your `claude login` OAuth
token and impersonates the Claude Code wire format. Meridian does the heavy
lifting; this repo wires it into opencode, sets up persistent autostart, and
deploys it to a VPS with auto-refreshing OAuth.

> **Looking for the legacy custom-subprocess provider** that ran `claude` as a
> child process per turn? See [`legacy/README.md`](legacy/README.md). It still
> works but is superseded by the meridian-based path documented here.

---

## Architecture

```
                          local machine
   ┌───────────────────────────────────────────────────────┐
   │                                                       │
   │   opencode TUI                                        │
   │       │                                               │
   │       │  HTTP (Anthropic-compatible)                  │
   │       ▼                                               │
   │   meridian @ 127.0.0.1:3456                           │
   │       │                                               │
   │       │  @anthropic-ai/claude-agent-sdk               │
   │       ▼                                               │
   │   claude binary subprocess                            │
   │       │                                               │
   │       │  OAuth from `claude login`                    │
   │       │  (macOS keychain / Linux ~/.claude)           │
   │       ▼                                               │
   └───────┼───────────────────────────────────────────────┘
           │
           ▼
       Anthropic API   (billed against Claude Pro / Max)
```

For a remote VPS the picture is identical except meridian runs on the VPS as a
systemd service, OAuth is provisioned once via `claude login`, and a 12-hour
keepalive timer prevents the refresh token from going stale during idle
periods. Local opencode reaches the remote meridian over Tailscale or an SSH
tunnel.

---

## Local install (macOS / Linux desktop)

One line:

```bash
curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/install.sh | bash
```

What it does:

1. Verifies `node ≥ 20`, `npm`, `opencode`, and `claude` are installed; bails
   out with actionable error messages if anything is missing.
2. Installs `@rynfar/meridian` globally with `--ignore-scripts` (the upstream
   postinstall has a known macOS issue with the `claude.exe` placeholder).
3. Runs `install.cjs` manually to materialise the platform-correct claude
   binary.
4. If `claude` has no active OAuth session, prompts you to run `claude login`.
5. Patches `~/.config/opencode/opencode.json`:
   - Sets `provider.anthropic.options.baseURL = http://127.0.0.1:3456`
   - Sets `provider.anthropic.options.apiKey  = "x"` (placeholder, not used)
   - Removes any `thinking` overrides so meridian's adaptive setting wins.
   - Adds the meridian plugin to the `plugin` array.
6. Writes `~/.config/meridian/sdk-features.json` with `thinking="adaptive"`
   and `thinkingPassthrough=true` so opencode receives `thinking` blocks.
7. Patches the meridian plugin to **force 200 k context** (subagent agent
   mode) so all traffic goes through your plan-limit pool, not the
   extra-usage 1 M pool. Override with `OPENCODE_CLAUDE_PROXY_USE_1M=1`.
8. Installs and bootstraps a `launchd` agent (macOS) or `systemd` unit
   (Linux) so meridian autostarts on login / boot and respawns on crash.
9. Hits `/healthz` to confirm the proxy is up, your OAuth is valid, and the
   subscription type is `pro` or `max`.

Re-run the same one-liner any time to pick up upstream meridian updates.

Optional environment overrides:

| Variable                           | Default                                                  | Purpose                                                                          |
| ---------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `OPENCODE_CONFIG`                  | `~/.config/opencode/opencode.json`                       | Which opencode config to patch.                                                  |
| `MERIDIAN_PORT`                    | `3456`                                                   | Port meridian binds to on `127.0.0.1`.                                           |
| `OPENCODE_CLAUDE_PROXY_USE_1M`     | _unset_                                                  | If set, **don't** force subagent mode; lets meridian use opus[1m] / sonnet[1m].  |
| `OPENCODE_CLAUDE_PROXY_NO_AUTOSTART` | _unset_                                                | Skip launchd / systemd installation.                                             |
| `OPENCODE_CLAUDE_PROXY_THINKING`   | `adaptive`                                               | One of `disabled` / `adaptive` / `enabled`. Written to `sdk-features.json`.      |

---

## VPS install

Pick one of the two:

### From your laptop (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/scripts/install-vps.sh | \
  bash -s -- --host vps.example.com
```

The script SSHs to `vps.example.com`, copies the necessary install material,
and runs it under your remote user. After it finishes you'll see a printable
summary with three connection options (Tailscale, SSH tunnel, raw public —
documented below).

### Directly on the VPS

```bash
ssh vps.example.com
curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/scripts/install-vps.sh | \
  bash -s -- --local
```

What the VPS install does:

1. Installs Node 20 (NodeSource APT repo on Debian/Ubuntu, `dnf` on Fedora).
2. Installs `@rynfar/meridian` globally and patches the postinstall.
3. Creates a dedicated `meridian` system user.
4. Installs `/etc/systemd/system/meridian.service` (always-on, restart=always,
   logs to `/var/log/meridian/meridian.log`).
5. Installs `/etc/systemd/system/meridian-keepalive.{service,timer}` — a
   12-hour timer that issues a 1-token request through meridian to the
   Anthropic API. This keeps the OAuth refresh-token chain warm so the VPS
   can sit idle for weeks without losing auth.
6. **Auth bootstrapping**:
   - If your laptop already has `claude login` done, the script offers to
     copy your OAuth credentials over SSH into `/var/lib/meridian/.claude/`.
   - Otherwise it walks you through running `claude login` on the VPS via an
     SSH browser-port-forward.
7. `systemctl enable --now` both units.
8. Verifies `/healthz` over the loopback and prints connection instructions.

### Connecting opencode to a remote meridian

Three options, in order of preference:

**A) Tailscale (recommended).** If your VPS is on your tailnet, set:

```jsonc
"provider": {
  "anthropic": {
    "options": { "baseURL": "http://<vps-tailnet-ip>:3456", "apiKey": "x" }
  }
}
```

The VPS install script auto-detects Tailscale and offers to bind meridian to
the tailnet interface. Encrypted, no public exposure, zero-conf access from
any device on your tailnet.

**B) SSH tunnel.** From your laptop:

```bash
ssh -fN -L 3456:127.0.0.1:3456 vps.example.com
```

opencode keeps using `http://127.0.0.1:3456` exactly as in the local install.
The script optionally writes a `~/.ssh/config` `RemoteForward` entry so the
tunnel auto-establishes on every SSH connection.

**C) Public bind.** Not recommended — meridian has no auth layer. If you
must, pass `--bind 0.0.0.0` and put it behind a reverse proxy with HTTPS
+ Basic Auth or mTLS. The script will refuse to do this without `--i-know`.

---

## Configuration files written

| Path                                                            | Owner        | Purpose                                                            |
| --------------------------------------------------------------- | ------------ | ------------------------------------------------------------------ |
| `~/.config/opencode/opencode.json`                              | local user   | opencode provider + plugin wiring; backed up before first edit.    |
| `~/.config/meridian/sdk-features.json`                          | local user   | Per-adapter feature flags (thinking, passthrough, claudeMd, …).    |
| `~/Library/LaunchAgents/dev.meridian.proxy.plist`               | local user (macOS) | Autostart + KeepAlive for meridian.                          |
| `/etc/systemd/system/meridian.service`                          | root (Linux) | Autostart + Restart=always for meridian on the VPS.                |
| `/etc/systemd/system/meridian-keepalive.{service,timer}`        | root (Linux) | 12-hour OAuth refresh ping on the VPS.                             |
| `/var/lib/meridian/.claude/`                                    | meridian (Linux) | Claude OAuth store on the VPS.                                 |

All writes are idempotent and produce timestamped backups (`*.bak.before-meridian-<unix>`).

---

## Verifying it works

```bash
curl -s http://127.0.0.1:3456/healthz | jq .
# {
#   "status": "healthy",
#   "version": "1.40.0",
#   "auth": { "loggedIn": true, "subscriptionType": "max", "email": "..." },
#   "mode": "passthrough",
#   "plugin": { "opencode": "configured" }
# }
```

In opencode itself:

```
> hello
```

Should respond from `claude-opus-4-7` instantly with no thinking block (adaptive).

```
> walk me through implementing a B-tree from scratch
```

Should emit a `thinking` block first, then the answer (adaptive again — the
model decided this prompt warrants thinking).

Tool calls, subagent dispatch, MCP tools, and streaming all work transparently
because meridian operates in **passthrough mode** — it forwards `tool_use`
events back to opencode, lets opencode execute the tool locally, and accepts
the `tool_result` on the next turn. No tools run inside meridian itself.

---

## Routing summary

The meridian plugin **only** intercepts requests for the `anthropic` provider.
Other providers configured in your `opencode.json` are unchanged:

| opencode provider                              | Route                                       |
| ---------------------------------------------- | ------------------------------------------- |
| `anthropic/*`                                  | → meridian → claude-agent-sdk → Anthropic   |
| `openai/*`, `minimax-coding-plan/*`, etc.      | → directly to that provider                 |
| `homeserver/*` (local llama.cpp etc.)          | → directly                                  |

Co-existence with [`oh-my-openagent`](https://github.com/code-yeongyu/oh-my-openagent)
multi-model orchestration works out of the box: anthropic-pinned agents
(build / plan / sisyphus / oracle / prometheus / metis / momus / etc.) flow
through meridian; minimax / openai / local agents bypass it entirely.

---

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/scripts/uninstall.sh | bash
```

Restores backed-up `opencode.json`, removes meridian plugin entry, unloads
launchd / systemd units, optionally `npm uninstall -g @rynfar/meridian`.

---

## Troubleshooting

| Symptom                                                              | Fix                                                                                                                                                |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `spawn ENOEXEC` from meridian on first start                         | Postinstall didn't materialise the `claude` Mach-O. Run `node /opt/homebrew/lib/node_modules/@rynfar/meridian/node_modules/@anthropic-ai/claude-code/install.cjs` and restart the launchd job. |
| `auth.loggedIn = false` in `/healthz`                                | Run `claude login` in a terminal where the keychain is unlocked; meridian re-reads on next request.                                                |
| opencode requests time out around 5–15 s                              | Old `opencode.json` had `thinking.budget_tokens=16384`. The installer should have removed it; verify and restart opencode.                          |
| `[PROXY] UNHANDLED GET /api/settings`                                 | Harmless — opencode polls a meridian endpoint that doesn't exist. Will be resolved upstream.                                                       |
| 1 M context still being used (`model=opus[1m]` in meridian log)      | Plugin wasn't patched, or `OPENCODE_CLAUDE_PROXY_USE_1M=1` was set during install. Re-run installer without the override.                          |
| VPS auth dies after weeks of idle                                     | Keepalive timer didn't fire. `systemctl status meridian-keepalive.timer` and check journal.                                                        |

Full meridian logs:

```
tail -f ~/.cache/meridian/meridian.log          # macOS
journalctl -u meridian -f                        # Linux VPS
```

---

## Why meridian over our previous approach?

The legacy approach (in `legacy/`) was a custom `LanguageModelV3`
implementation that spawned `claude --output-format stream-json` per turn and
translated the stream into AI SDK v3 events. It worked but had three problems:

1. **Fragile against opencode + AI SDK upgrades.** Every minor opencode bump
   changed something subtle in the V3 stream contract.
2. **No subagent dispatch.** The `Task` tool delegations didn't round-trip
   correctly through the subprocess bridge.
3. **No thinking blocks.** Stream-json filtered them.

Meridian solves all three at the source by using the official
`@anthropic-ai/claude-agent-sdk`, which is the *exact same code path* the
`claude` CLI uses. Wire format identical, fingerprint clean, every feature
that works in `claude` works here.

---

## License

MIT.
