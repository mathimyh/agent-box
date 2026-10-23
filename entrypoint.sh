#!/bin/bash
# Container entrypoint. The launcher (agent-box.ps1) stages sanitized host
# config in /host-config. This script copies it into the home volume and
# starts the requested agent.
set -euo pipefail

HOME_DIR=/home/agent
STAGE=/host-config

mkdir -p "$HOME_DIR/.claude/plugins" "$HOME_DIR/.config"

# Claude Code: settings, global instructions, plugin registries.
# skills/, commands/, plugins/cache/, plugins/marketplaces/ are read-only bind mounts.
cp "$STAGE/claude/settings.json" "$HOME_DIR/.claude/settings.json"
cp "$STAGE/claude/CLAUDE.md" "$HOME_DIR/.claude/CLAUDE.md"
cat /etc/agent-box/container-instructions.md >> "$HOME_DIR/.claude/CLAUDE.md"
cp "$STAGE/claude/installed_plugins.json" "$HOME_DIR/.claude/plugins/installed_plugins.json"
cp "$STAGE/claude/known_marketplaces.json" "$HOME_DIR/.claude/plugins/known_marketplaces.json"

# Git: match the host line-ending policy and let gh handle https auth.
if [ -n "${GIT_AUTOCRLF:-}" ]; then
  git config --global core.autocrlf "$GIT_AUTOCRLF"
fi
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null 2>&1 || true
fi

# opencode binds its MCP OAuth callback to 127.0.0.1:19876 only. Relay the
# published container port to loopback so the host browser can complete the flow.
if [ -n "${AGENT_BOX_OAUTH_RELAY:-}" ]; then
  ip=$(hostname -I | awk '{print $1}')
  socat "TCP-LISTEN:19876,bind=${ip},fork,reuseaddr" TCP:127.0.0.1:19876 &
fi

# Orca CLI: pair with the filtering proxy once. The launcher passes its pairing
# link. The pairing is kept in the home volume, shared by all containers.
if [ -n "${ORCA_ENVIRONMENT:-}" ] && [ -n "${AGENT_BOX_ORCA_LINK:-}" ] && [ -d /opt/orca-cli ] \
   && ! orca environment show --environment "$ORCA_ENVIRONMENT" >/dev/null 2>&1; then
  orca environment add --name "$ORCA_ENVIRONMENT" --pairing-code "$AGENT_BOX_ORCA_LINK" >/dev/null 2>&1 \
    || echo "agent-box: could not pair the Orca CLI with the proxy" >&2
fi
unset AGENT_BOX_ORCA_LINK

# node_modules volumes. The launcher lists each package that has a
# package-lock.json. Run npm ci when the lock file changed since the last
# install. The agent starts after this, so it never runs npm at the same time.
# A failed install writes no marker, so the next start tries again.
if [ -n "${AGENT_BOX_NPM_PACKAGES:-}" ]; then
  IFS=: read -ra packages <<< "$AGENT_BOX_NPM_PACKAGES"
  for pkg in "${packages[@]}"; do
    dir="/work/$pkg"
    marker="$dir/node_modules/.agent-box-lock-sha256"
    [ -f "$dir/package-lock.json" ] || continue
    sum=$(sha256sum "$dir/package-lock.json" | cut -d' ' -f1)
    if [ "$(cat "$marker" 2>/dev/null)" = "$sum" ]; then
      continue
    fi
    echo "agent-box: npm ci in $pkg"
    if (cd "$dir" && npm ci); then
      echo "$sum" > "$marker"
    else
      echo "agent-box: npm ci failed in $pkg. The agent starts without a complete node_modules." >&2
    fi
  done
fi

agent="${1:-claude}"
shift || true

case "$agent" in
  claude)
    exec claude --mcp-config "$STAGE/claude/mcp.json" "$@"
    ;;
  opencode)
    exec opencode "$@"
    ;;
  shell)
    if [ -n "${AGENT_BOX_COMMAND:-}" ]; then
      exec bash -lc "$AGENT_BOX_COMMAND"
    fi
    exec bash
    ;;
  *)
    echo "agent-box: unknown agent '$agent' (claude|opencode|shell)" >&2
    exit 2
    ;;
esac
