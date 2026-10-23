#!/bin/sh
# Runs as the agent user from install.sh. Merges the kit config into the
# files that the agent kit and Orca also write, so their keys stay.
set -eu

ASSETS="$HOME/.local/share/agent-box"

merge() {
  target="$1"
  patch="$2"
  [ -f "$target" ] || echo '{}' > "$target"
  jq -s '.[0] * .[1]' "$target" "$patch" > "$target.tmp"
  mv "$target.tmp" "$target"
}

# Host settings without host-only keys. Keeps Orca's hooks and the agent
# kit's permission mode.
merge "$HOME/.claude/settings.json" "$ASSETS/claude-settings.json"

# First-run flags. Without them Claude shows prompts that swallow the first
# dispatched task.
merge "$HOME/.claude.json" "$ASSETS/claude-json.json"

# Git identity from the host.
git config --global include.path "$ASSETS/gitconfig"
