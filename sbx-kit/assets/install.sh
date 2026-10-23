#!/bin/sh
# Kit install step. Runs once as root when the sandbox is created or when the
# kit is added with `sbx kit add`. The kit files are already in /home/agent.
# Every step is safe to run again.
set -eu

ASSETS=/home/agent/.local/share/agent-box
export DEBIAN_FRONTEND=noninteractive

# .NET needs ICU. jq merges the Claude config below.
apt-get update
apt-get install -y --no-install-recommends libicu-dev jq
rm -rf /var/lib/apt/lists/*

# .NET SDK 10. The install script works on every Debian-like image.
if [ ! -x /usr/share/dotnet/dotnet ]; then
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet --no-path
  rm -f /tmp/dotnet-install.sh
fi
ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet

# OpenShift client.
if [ ! -x /usr/local/bin/oc ]; then
  curl -fsSL https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable-4.15/openshift-client-linux.tar.gz \
    | tar -xz -C /usr/local/bin oc kubectl
fi

# opencode, with the approved permissions as managed config.
# See opencode-managed.json in the agent-box repo.
command -v opencode >/dev/null 2>&1 || npm install -g opencode-ai
mkdir -p /etc/opencode
cp "$ASSETS/opencode-managed.json" /etc/opencode/opencode.json

# Environment for every shell, also SSH sessions from Orca.
if ! grep -q 'agent-box' /etc/sandbox-persistent.sh 2>/dev/null; then
  cat >> /etc/sandbox-persistent.sh <<'EOF'
# agent-box
export DOTNET_ROOT=/usr/share/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
export OPENCODE_DISABLE_PROJECT_CONFIG=1
export NPM_CONFIG_PREFER_OFFLINE=true NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_FETCH_TIMEOUT=60000
EOF
fi

# Claude and git config of the agent user.
chown -R agent:agent /home/agent/.claude /home/agent/.config /home/agent/.local/share/agent-box
su agent -c "sh $ASSETS/agent-config.sh"
