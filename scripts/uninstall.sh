#!/usr/bin/env bash
# opencode-claude-proxy — uninstaller (local desktop)
#
# Removes:
#   - launchd / systemd-user unit
#   - meridian plugin from opencode.json (restores latest *.bak.before-meridian-* if found)
#   - sdk-features.json
# Leaves alone:
#   - the npm package (run `npm uninstall -g @rynfar/meridian` separately if you want)
#   - your `claude login` OAuth (run `claude logout` if you want to wipe that)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/iamtheavoc1/opencode-claude-proxy/main/scripts/uninstall.sh | bash

set -euo pipefail

CONFIG_PATH="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

c_green()  { printf '\033[32m%s\033[0m' "$1"; }
c_yellow() { printf '\033[33m%s\033[0m' "$1"; }
c_cyan()   { printf '\033[36m%s\033[0m' "$1"; }
step() { printf '\n%s %s\n' "$(c_cyan '==>')" "$1"; }
ok()   { printf '    %s %s\n' "$(c_green '✓')"  "$1"; }
warn() { printf '    %s %s\n' "$(c_yellow '!')" "$1"; }

case "$(uname -s)" in
  Darwin)
    step "Removing launchd agent"
    PLIST="$HOME/Library/LaunchAgents/dev.meridian.proxy.plist"
    if [ -f "$PLIST" ]; then
      launchctl bootout "gui/$(id -u)/dev.meridian.proxy" 2>/dev/null || true
      mv "$PLIST" "$PLIST.removed-$(date +%s)"
      ok "moved $PLIST out of LaunchAgents"
    else
      warn "no plist at $PLIST"
    fi
    ;;
  Linux)
    step "Removing systemd --user unit"
    UNIT="$HOME/.config/systemd/user/meridian.service"
    if [ -f "$UNIT" ]; then
      systemctl --user disable --now meridian.service 2>/dev/null || true
      mv "$UNIT" "$UNIT.removed-$(date +%s)"
      systemctl --user daemon-reload || true
      ok "removed $UNIT"
    else
      warn "no unit at $UNIT"
    fi
    ;;
esac

step "Restoring opencode.json"
if [ -f "$CONFIG_PATH" ]; then
  LATEST_BAK=$(ls -1t "$CONFIG_PATH".bak.before-meridian-* 2>/dev/null | head -1 || true)
  if [ -n "$LATEST_BAK" ]; then
    cp "$CONFIG_PATH" "$CONFIG_PATH.before-uninstall-$(date +%s)"
    cp "$LATEST_BAK" "$CONFIG_PATH"
    ok "restored from $LATEST_BAK"
  else
    warn "no pre-install backup found; leaving $CONFIG_PATH alone"
    warn "manual removal: delete the meridian plugin entry and provider.anthropic.options.baseURL"
  fi
fi

step "Removing meridian sdk-features"
SDKF="$HOME/.config/meridian/sdk-features.json"
if [ -f "$SDKF" ]; then
  mv "$SDKF" "$SDKF.removed-$(date +%s)"
  ok "moved $SDKF aside"
fi

step "Done"
echo
echo "  To also remove the npm package:"
echo "      npm uninstall -g @rynfar/meridian"
echo
echo "  To wipe Claude OAuth:"
echo "      claude logout"
