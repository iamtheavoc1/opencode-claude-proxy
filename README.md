# opencode-anthropic-auth-fix

The repo name is historical. Today this project is a **general-purpose Anthropic OAuth repair and refresh toolkit for OpenCode + Claude Code users**.

It does two jobs:

1. fixes the OpenCode request-shape problem that causes the misleading **"You're out of extra usage"** error
2. keeps Anthropic OAuth tokens usable with a manual flow, a recurring local flow, or a remote VPS-offload flow

## The short version

If you want a one-time/manual setup:

```bash
bash ./install.sh --mode=manual
```

If you want local recurring refresh while your machine is awake:

```bash
bash ./install.sh --mode=recurring-local
```

If you want refresh to keep running while your laptop sleeps or is shut down, follow:

- [`docs/REMOTE-VPS.md`](./docs/REMOTE-VPS.md)

If you want **OpenCode itself** to keep running while your Mac is closed, use:

- [`docs/RUN-OPENCODE-REMOTELY.md`](./docs/RUN-OPENCODE-REMOTELY.md)

## First-time requirement

If you have never logged into Claude Code on this machine, do this once first:

```bash
claude auth login
```

After that, run one of the install commands above.

## What gets installed

The installer writes runtime helpers to:

```text
~/.local/share/opencode-anthropic-auth/
```

Main helpers:

- `doctor.mjs` — inspect, refresh, or auto-fix auth state
- `recover.sh` — walk through one-time recovery after a dead token chain
- `reset.sh` — delete the stored Anthropic OAuth entry for a clean slate
- `refresh-token.mjs` — recurring local refresher
- `pull-from-vps.sh` — on-demand pull when VPS-offload mode is enabled

Repo-level convenience wrappers:

- `./install.sh`
- `./doctor.sh`
- `./reset.sh`

## Three supported approaches

### 1) Manual mode

Best when you want zero background jobs.

Install:

```bash
bash ./install.sh --mode=manual
```

What it does:

- installs the OpenCode fix
- installs `doctor.mjs`, `recover.sh`, and `reset.sh`
- installs the `claude()` shell wrapper
- **does not** install LaunchAgent / cron

Use it when you want to refresh once on demand:

```bash
./doctor.sh status
./doctor.sh refresh --force
```

### 2) Recurring local mode

Best when your machine stays awake often enough.

Install:

```bash
bash ./install.sh --mode=recurring-local
```

What it does:

- everything from manual mode
- plus a local recurring refresher
  - macOS: LaunchAgent
  - Linux: cron

This is the best local option, but it still cannot beat a laptop with the lid closed for a long time. If the machine is really asleep, no local script can keep refreshing forever.

Important distinction on macOS:

- **screen locked**: usually fine, as long as the Mac is still awake and allowed to run background jobs
- **lid closed**: not fine for local execution; macOS sleep stops local refresh jobs and stops a locally-running OpenCode process too

### 3) Remote VPS-offload mode

Best when you want the refresh chain to survive while your laptop is offline.

Use the tutorial here:

- [`docs/REMOTE-VPS.md`](./docs/REMOTE-VPS.md)

That mode moves recurring refresh to a Linux VPS and turns your laptop into an on-demand consumer.

That solves the **token survival** problem while your Mac is closed.

If you also want the **OpenCode process itself** to continue while your Mac is closed, run OpenCode on the remote machine in `tmux` or a similar session manager. See [`docs/RUN-OPENCODE-REMOTELY.md`](./docs/RUN-OPENCODE-REMOTELY.md).

## The doctor commands

`doctor.mjs` is the main health tool.

Examples:

```bash
./doctor.sh status
./doctor.sh status --json
./doctor.sh doctor --fix
./doctor.sh refresh --force
```

Subcommands:

- `status` — diagnose only
- `doctor --fix` — diagnose and auto-remediate when possible
- `refresh --force` — force a live refresh attempt even if the stored expiry still looks healthy
- `env` — print the `CLAUDE_CODE_OAUTH_*` exports used by the wrapper

### Exit codes

| Code | Meaning | Typical examples |
| --- | --- | --- |
| `0` | healthy | token fresh, or fixed successfully |
| `1` | fixable | near expiry, VPS stale, transient upstream/network problem |
| `2` | terminal / re-login required | missing auth.json, corrupt auth.json, no anthropic entry, dead refresh token |

## Why "Invalid authentication credentials" keeps happening

There are two different problems that can produce the same pain:

1. **stale access token** — the access token is no longer accepted, but the refresh token still works
2. **dead refresh chain** — Anthropic rejects the refresh token itself (`invalid_grant`, revoked token, missing token)

This repo now handles them differently:

- on a normal expiry problem, the wrapper and doctor force a refresh and retry
- on a dead refresh token, the scripts stop pretending they can heal it and print numbered next steps

It also separates two different uptime goals that are easy to confuse:

- **keep auth alive** while your Mac sleeps or is closed → use VPS-offload
- **keep OpenCode itself running** while your Mac is closed → run OpenCode remotely

That distinction matters. A revoked refresh token can never be made truly "never happen again" by local automation alone. One fresh login is still required when the upstream refresh chain is gone.

## What to do when the token is dead

If `doctor.sh` reports `REFRESH_TOKEN_DEAD`, use this order:

```bash
claude auth login
~/.local/share/opencode-anthropic-auth/recover.sh
./doctor.sh refresh --force
```

Then retry your original Claude/OpenCode command.

If you want a clean slate first:

```bash
./reset.sh --yes
```

That removes the stored Anthropic OAuth entry from `~/.local/share/opencode/auth.json`.

## What `recover.sh` does

`recover.sh` is the guided recovery path.

It:

1. prompts for a one-time browser login/token capture
2. writes the new Anthropic token into `auth.json`
3. kicks the normal refresh path so a proper access+refresh pair is re-established

If the scripts tell you to run `recover.sh`, they are telling you the current chain cannot be recovered silently anymore.

## What `reset.sh` does

`reset.sh` exists for the "please delete the broken token and let me start over" case.

Run:

```bash
./reset.sh --yes
```

Then do:

```bash
claude auth login
~/.local/share/opencode-anthropic-auth/recover.sh
```

## The `claude()` wrapper

The installer adds a shell function that:

- loads `CLAUDE_CODE_OAUTH_TOKEN`
- loads `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`
- loads `CLAUDE_CODE_OAUTH_SCOPES`
- runs a local `claude-sync` after a successful `claude auth login` / `setup-token`
- retries once after an auth failure
- tries a local Claude→OpenCode resync before falling back to VPS/manual recovery
- forces a real refresh on 401-like errors instead of trusting the local expiry timestamp blindly

That last point is important: a token can look unexpired locally and still be rejected upstream. The wrapper now treats that as a live refresh signal.

## OpenCode fix: the original root cause

The auth tooling is only half the story. This repo also fixes the actual OpenCode/Anthropic request-shape bug.

Anthropic OAuth requests are stricter than most third-party wrappers assume. For Claude Code-billed traffic, `system[]` must contain only the Claude identity block. Extra system blocks from OpenCode agent prompts, tools, or orchestration layers get rejected and surface as the misleading **"You're out of extra usage"** message.

This installer uses [`@ex-machina/opencode-anthropic-auth`](https://www.npmjs.com/package/@ex-machina/opencode-anthropic-auth), which rewrites those extra `system[]` blocks into the first user message so OpenCode continues to work without tripping Anthropic's validation.

## Troubleshooting

### `Invalid authentication credentials`

Run:

```bash
./doctor.sh status
./doctor.sh refresh --force
```

If that ends in `REFRESH_TOKEN_DEAD`, do:

```bash
claude auth login
~/.local/share/opencode-anthropic-auth/recover.sh
```

If `claude auth login` succeeds but OpenCode still fails immediately afterward, run:

```bash
claude-sync
```

New installs now do that sync automatically after a successful wrapper-mediated Claude login.

### `auth.json` missing / corrupt / no anthropic entry

Use:

```bash
claude auth login
~/.local/share/opencode-anthropic-auth/recover.sh
```

### Local machine sleeps too much

Use the remote path:

- [`docs/REMOTE-VPS.md`](./docs/REMOTE-VPS.md)

### Mac is locked vs Mac is closed

- **Locked but awake**: local recurring mode can still work, and VPS-offload also works
- **Closed lid**: your local Mac will sleep; local OpenCode and local refresh jobs cannot continue there

If you need work to continue while the lid is closed, use:

- [`docs/REMOTE-VPS.md`](./docs/REMOTE-VPS.md) for token survival
- [`docs/RUN-OPENCODE-REMOTELY.md`](./docs/RUN-OPENCODE-REMOTELY.md) for actually running OpenCode remotely

### Re-run the installer

You can safely re-run either:

```bash
bash ./install.sh --mode=manual
bash ./install.sh --mode=recurring-local
```

## Credits

The actual request-rewrite fix comes from [`@ex-machina/opencode-anthropic-auth`](https://www.npmjs.com/package/@ex-machina/opencode-anthropic-auth) by [ex-machina-co](https://github.com/ex-machina-co/opencode-anthropic-auth). This repo turns that into an easier install + recovery + token lifecycle toolkit.

## License

[MIT](./LICENSE)
