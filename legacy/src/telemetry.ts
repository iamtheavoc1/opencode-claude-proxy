// Cache-aware telemetry.
//
// Writes one JSONL line per completed request to
//   $OPENCODE_TELEMETRY_PATH  (if set)
//   else ~/.opencode/cache-telemetry.jsonl
//
// Each line captures the Anthropic cache metrics (cache_read /
// cache_creation / non-cached input), raw token counts, and the
// session identifiers opencode-claude-proxy already tracks, so you can
// answer "is Claude CLI's auto-cache_control actually hitting?" with
// real data from live opencode sessions.
//
// Telemetry MUST NEVER crash the provider. All writes are wrapped in
// best-effort try/catch. Disable by setting OPENCODE_TELEMETRY=0.
//
// Quick analysis one-liners:
//
//   # aggregate hit rate across all requests
//   jq -s 'map(.inputTokens) |
//          { cacheRead: (map(.cacheRead//0)|add),
//            cacheWrite:(map(.cacheWrite//0)|add),
//            noCache:   (map(.noCache//0)|add) } |
//          . + { hitRate: (.cacheRead / (.cacheRead + .cacheWrite + .noCache) * 100 | floor) }' \
//     ~/.opencode/cache-telemetry.jsonl
//
//   # per-session hit rate
//   jq -s 'group_by(.sessionId)[] | {
//            session: .[0].sessionId,
//            turns:   length,
//            cacheRead:  (map(.inputTokens.cacheRead//0)  | add),
//            cacheWrite: (map(.inputTokens.cacheWrite//0) | add),
//            noCache:    (map(.inputTokens.noCache//0)    | add) }' \
//     ~/.opencode/cache-telemetry.jsonl

import { appendFileSync, mkdirSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join } from "node:path"

import { log } from "./logger.ts"
import type { V3Usage } from "./usage.ts"

const DISABLED = process.env.OPENCODE_TELEMETRY === "0"

function resolvePath(): string {
  const override = process.env.OPENCODE_TELEMETRY_PATH
  if (override && override.trim().length > 0) return override
  return join(homedir(), ".opencode", "cache-telemetry.jsonl")
}

const TELEMETRY_PATH = resolvePath()
let dirEnsured = false

function ensureDir() {
  if (dirEnsured) return
  try {
    mkdirSync(dirname(TELEMETRY_PATH), { recursive: true })
    dirEnsured = true
  } catch (err: any) {
    log.warn("telemetry.mkdir", { path: TELEMETRY_PATH, message: err?.message })
  }
}

export interface TelemetryRecord {
  /** ISO timestamp when the result line arrived. */
  ts: string
  /** Provider name as configured (usually "claude-proxy"). */
  provider: string
  /** Model id opencode asked for (e.g. "sonnet"). */
  modelId: string
  /** Claude CLI session id (persists across turns in the same cwd+model). */
  sessionId: string | null
  /** Total USD billed for this turn as reported by the CLI `result` line. */
  costUsd: number | null
  /** Wall-clock ms for this turn as reported by the CLI. */
  durationMs: number | null
  /** Whether this was the first turn on a freshly-spawned subprocess. */
  spawnedFresh: boolean
  /** AI SDK v3 usage — we copy a subset so the record stays self-contained. */
  inputTokens: {
    total: number | undefined
    noCache: number | undefined
    cacheRead: number | undefined
    cacheWrite: number | undefined
  }
  outputTokens: {
    total: number | undefined
    reasoning: number | undefined
  }
  /** Convenience: cacheRead / (cacheRead + cacheWrite + noCache), 0..1 or null. */
  cacheHitRate: number | null
}

function computeHitRate(u: V3Usage): number | null {
  const r = u.inputTokens.cacheRead ?? 0
  const w = u.inputTokens.cacheWrite ?? 0
  const n = u.inputTokens.noCache ?? 0
  const denom = r + w + n
  if (denom <= 0) return null
  return r / denom
}

export interface EmitOptions {
  provider: string
  modelId: string
  sessionId: string | null
  costUsd: number | null
  durationMs: number | null
  spawnedFresh: boolean
  usage: V3Usage
}

export function emitTelemetry(opts: EmitOptions): void {
  if (DISABLED) return
  const rec: TelemetryRecord = {
    ts: new Date().toISOString(),
    provider: opts.provider,
    modelId: opts.modelId,
    sessionId: opts.sessionId,
    costUsd: opts.costUsd,
    durationMs: opts.durationMs,
    spawnedFresh: opts.spawnedFresh,
    inputTokens: {
      total: opts.usage.inputTokens.total,
      noCache: opts.usage.inputTokens.noCache,
      cacheRead: opts.usage.inputTokens.cacheRead,
      cacheWrite: opts.usage.inputTokens.cacheWrite,
    },
    outputTokens: {
      total: opts.usage.outputTokens.total,
      reasoning: opts.usage.outputTokens.reasoning,
    },
    cacheHitRate: computeHitRate(opts.usage),
  }

  try {
    ensureDir()
    appendFileSync(TELEMETRY_PATH, JSON.stringify(rec) + "\n", { encoding: "utf8" })
  } catch (err: any) {
    log.warn("telemetry.write", { path: TELEMETRY_PATH, message: err?.message })
  }
}

export function telemetryPath(): string {
  return TELEMETRY_PATH
}
