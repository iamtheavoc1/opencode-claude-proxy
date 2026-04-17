#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"

OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
MODELS_CACHE="${OPENCODE_MODELS_CACHE:-$HOME/.cache/opencode/models.json}"

DRY_RUN=0
REVERT=0
CONTEXT_LIMIT=200000
OUTPUT_LIMIT=128000
EFFORT="xhigh"
DISPLAY="summarized"

print_help() {
  cat <<'EOF'
Usage: enable-opus-4-7-thinking.sh [options]

Makes Claude Opus 4.7 actually surface its extended thinking in OpenCode by:

  1. Adding thinking + effort to claude-opus-4-7.options in opencode.json
     (adaptive thinking is the only mode Opus 4.7 accepts; display:summarized
      is required because 4.7 silently defaults to display:omitted)

  2. Patching the models.dev capability cache so the context meter shows
     200k instead of 1M (the 1M extended beta tier needs a separate
     anthropic-beta header and tier-4 billing that most subscriptions
     don't have; 200k is the correct default for subscription OAuth)

Before-and-after result fragment of opencode.json:

  provider.anthropic.models.claude-opus-4-7.options = {
    "effort": "xhigh",
    "thinking": { "type": "adaptive", "display": "summarized" }
  }

Options:
  --dry-run              Show what would change, write nothing.
  --revert               Remove the thinking block and restore cache to 1M.
                         Uses the backup files written on the last apply.
  --display <v>          summarized | omitted   (default: summarized)
  --effort <v>           low | medium | high | xhigh | max   (default: xhigh)
  --context <n>          Context limit in tokens (default: 200000)
  --output <n>           Output limit in tokens (default: 128000)
  --config <path>        opencode.json path (default: ~/.config/opencode/opencode.json)
  --models-cache <path>  models.json cache path (default: ~/.cache/opencode/models.json)
  --help, -h             Show this help
  --version, -v          Show version

Backups are written to <file>.bak-pre-opus47-thinking on first apply.
Restart OpenCode after running this: pkill -x opencode; opencode
EOF
}

log() { printf '    %s\n' "$*"; }
ok()  { printf '    ok: %s\n' "$*"; }
warn(){ printf '    warn: %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)       print_help; exit 0 ;;
    --version|-v)    echo "enable-opus-4-7-thinking v${VERSION}"; exit 0 ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --revert)        REVERT=1; shift ;;
    --display)       DISPLAY="$2"; shift 2 ;;
    --effort)        EFFORT="$2"; shift 2 ;;
    --context)       CONTEXT_LIMIT="$2"; shift 2 ;;
    --output)        OUTPUT_LIMIT="$2"; shift 2 ;;
    --config)        OPENCODE_CONFIG="$2"; shift 2 ;;
    --models-cache)  MODELS_CACHE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; print_help >&2; exit 1 ;;
  esac
done

command -v python3 >/dev/null 2>&1 || { echo "python3 not found" >&2; exit 1; }

if [[ ! -f "$OPENCODE_CONFIG" ]]; then
  echo "opencode.json not found at $OPENCODE_CONFIG" >&2
  echo "Run fix-opencode.sh first, or pass --config <path>." >&2
  exit 1
fi

export OPENCODE_CONFIG MODELS_CACHE DRY_RUN REVERT CONTEXT_LIMIT OUTPUT_LIMIT EFFORT DISPLAY

python3 <<'PY'
import json, os, shutil, sys

cfg_path    = os.environ['OPENCODE_CONFIG']
cache_path  = os.environ['MODELS_CACHE']
dry         = os.environ['DRY_RUN'] == '1'
revert      = os.environ['REVERT']  == '1'
ctx_limit   = int(os.environ['CONTEXT_LIMIT'])
out_limit   = int(os.environ['OUTPUT_LIMIT'])
effort      = os.environ['EFFORT']
display     = os.environ['DISPLAY']

if display not in ('summarized', 'omitted'):
    sys.exit(f'invalid --display: {display}')
if effort not in ('low', 'medium', 'high', 'xhigh', 'max'):
    sys.exit(f'invalid --effort: {effort}')

def find_model_container(node):
    if not isinstance(node, dict):
        return None
    if 'claude-opus-4-7' in node and isinstance(node['claude-opus-4-7'], dict):
        return node
    for v in node.values():
        r = find_model_container(v)
        if r is not None:
            return r
    return None

def apply_opencode_config():
    with open(cfg_path) as f:
        cfg = json.load(f)

    container = find_model_container(cfg)
    if container is None:
        print(f'    opencode.json has no claude-opus-4-7 entry — nothing to patch')
        print(f'    add this first, or set "model": "anthropic/claude-opus-4-7" as default')
        return False

    m = container['claude-opus-4-7']
    backup = cfg_path + '.bak-pre-opus47-thinking'

    if revert:
        changed = False
        if 'options' in m and 'thinking' in m['options']:
            del m['options']['thinking']; changed = True
        if 'options' in m and 'effort' in m['options']:
            del m['options']['effort']; changed = True
        if not changed:
            print('    opencode.json already clean')
            return False
        print(f'    opencode.json: removing thinking+effort from claude-opus-4-7')
    else:
        m.setdefault('limit', {})
        m['limit']['context'] = ctx_limit
        m['limit']['output']  = out_limit
        opts = m.setdefault('options', {})
        opts['effort']   = effort
        opts['thinking'] = {'type': 'adaptive', 'display': display}
        print(f'    opencode.json: claude-opus-4-7.options =')
        print('      ' + json.dumps(opts, indent=2).replace('\n', '\n      '))

    if dry:
        print('    (dry-run) not written')
        return True
    if not os.path.exists(backup):
        shutil.copy2(cfg_path, backup)
        print(f'    backup: {backup}')
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
    return True

def apply_models_cache():
    if not os.path.exists(cache_path):
        print(f'    models cache {cache_path} not present — skipping')
        return False

    with open(cache_path) as f:
        data = json.load(f)

    anth = data.get('anthropic', {}).get('models', {})
    if 'claude-opus-4-7' not in anth:
        print('    models cache has no claude-opus-4-7 entry — skipping')
        return False

    m = anth['claude-opus-4-7']
    backup = cache_path + '.bak-pre-opus47-thinking'
    limit = m.setdefault('limit', {})

    if revert:
        limit['context'] = 1000000
        limit['output']  = 128000
        print(f'    models cache: restoring claude-opus-4-7 context=1000000 output=128000')
    else:
        limit['context'] = ctx_limit
        limit['output']  = out_limit
        print(f'    models cache: claude-opus-4-7 context={ctx_limit} output={out_limit}')

    if dry:
        print('    (dry-run) not written')
        return True
    if not os.path.exists(backup):
        shutil.copy2(cache_path, backup)
        print(f'    backup: {backup}')
    with open(cache_path, 'w') as f:
        json.dump(data, f, indent=2)
    return True

print('==> opencode.json')
apply_opencode_config()
print('==> models cache')
apply_models_cache()
print()
print('Done. Restart OpenCode for the changes to take effect:')
print('  pkill -x opencode 2>/dev/null; opencode')
PY
