#!/bin/sh
# Kit install step. Runs once as root when the sandbox is created. `sbx kit
# add` refuses this kit: it declares files/ and credentials.
# Every step is safe to run again.
set -eu

ASSETS=/home/agent/.local/share/agent-box
export DEBIAN_FRONTEND=noninteractive

# Pinned tool versions: opencode and npm. Two sandboxes created on
# different days get the same versions. Change a pin on purpose. After an
# opencode change, run `opencode debug config` in a new sandbox and check
# that the project config is still hidden. See docs/design.md.
# The .NET SDK and oc are not installed here: they live in kits under
# kits/ (kits/dotnet, kits/intility-id).
OPENCODE_VERSION=1.19.3
NPM_VERSION=11.21.1

# jq merges the Claude config below and the opencode patches of the project
# kits. It comes from the Ubuntu archives, which the global policy allows.
apt-get update
apt-get install -y --no-install-recommends jq
rm -rf /var/lib/apt/lists/*

# The image has Ubuntu's npm 9.2.0. With Node 22 it fails `npm ci` with
# ECONNRESET ("aborted") when it downloads many packages.
npm install -g "npm@$NPM_VERSION"

# opencode, with the approved permissions as managed config.
# See opencode-managed.json in the agent-box repo.
command -v opencode >/dev/null 2>&1 || npm install -g "opencode-ai@$OPENCODE_VERSION"
mkdir -p /etc/opencode
cp "$ASSETS/opencode-managed.json" /etc/opencode/opencode.json
# opencode tells the agent it can write to /tmp/opencode. Without this,
# workers found it owned by root and could not write there.
mkdir -p /tmp/opencode
chown agent:agent /tmp/opencode

# Environment for every shell, also SSH sessions from Orca.
if ! grep -q 'agent-box' /etc/sandbox-persistent.sh 2>/dev/null; then
  cat >> /etc/sandbox-persistent.sh <<'EOF'
# agent-box
export OPENCODE_DISABLE_PROJECT_CONFIG=1
export NPM_CONFIG_PREFER_OFFLINE=true NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_FETCH_TIMEOUT=60000
EOF
fi

# Claude and git config of the agent user.
chown -R agent:agent /home/agent/.claude /home/agent/.config /home/agent/.local/share/agent-box
su agent -c "sh $ASSETS/agent-config.sh"
