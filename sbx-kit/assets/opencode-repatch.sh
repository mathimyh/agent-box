#!/bin/sh
# Runs as root from sync.ps1. A sync replaces the base opencode configs, so
# the project-kit patches must be merged again. Same merges as the kit install
# steps in kits/<project>/spec.yaml: permission rules into /etc/opencode, the
# MCP gateway entry into the agent user config. A sandbox without a project
# kit has no patch files, and the loop does nothing.
set -eu

ASSETS=/home/agent/.local/share/agent-box
USER_CONFIG=/home/agent/.config/opencode/opencode.json

for patch in "$ASSETS"/*/opencode-patch.json; do
  [ -f "$patch" ] || continue
  jq -s '.[0].permission = (.[0].permission * .[1].permission) | .[0]' \
    /etc/opencode/opencode.json "$patch" > /etc/opencode/opencode.json.tmp
  mv /etc/opencode/opencode.json.tmp /etc/opencode/opencode.json
  jq -s '.[0].mcp = ((.[0].mcp // {}) * .[1].mcp) | .[0]' \
    "$USER_CONFIG" "$patch" > "$USER_CONFIG.tmp"
  mv "$USER_CONFIG.tmp" "$USER_CONFIG"
done

chown agent:agent "$USER_CONFIG"
