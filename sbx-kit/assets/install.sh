#!/bin/sh
# Kit install step. Runs once as root when the sandbox is created or when the
# kit is added with `sbx kit add`. The kit files are already in /home/agent.
# Every step is safe to run again.
set -eu

ASSETS=/home/agent/.local/share/agent-box
export DEBIAN_FRONTEND=noninteractive

# Pinned tool versions: opencode, npm and oc. Two sandboxes created on
# different days get the same versions. Change a pin on purpose. After an
# opencode change, run `opencode debug config` in a new sandbox and check
# that the project config is still hidden. See docs/design.md.
OPENCODE_VERSION=1.19.3
NPM_VERSION=11.21.1
OC_VERSION=4.15.59

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

# OpenShift client, pinned. The checksum comes from the same mirror
# directory. The install stops when the archive does not match it.
if [ ! -x /usr/local/bin/oc ]; then
  oc_base="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$OC_VERSION"
  curl -fsSL "$oc_base/openshift-client-linux.tar.gz" -o /tmp/openshift-client-linux.tar.gz
  curl -fsSL "$oc_base/sha256sum.txt" -o /tmp/ocp-sha256sum.txt
  grep ' openshift-client-linux.tar.gz$' /tmp/ocp-sha256sum.txt > /tmp/ocp-check.txt
  (cd /tmp && sha256sum -c ocp-check.txt)
  tar -xzf /tmp/openshift-client-linux.tar.gz -C /usr/local/bin oc kubectl
  rm -f /tmp/openshift-client-linux.tar.gz /tmp/ocp-sha256sum.txt /tmp/ocp-check.txt
fi

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
export DOTNET_ROOT=/usr/share/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
export OPENCODE_DISABLE_PROJECT_CONFIG=1
export NPM_CONFIG_PREFER_OFFLINE=true NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false NPM_CONFIG_FETCH_TIMEOUT=60000
EOF
fi

# Claude and git config of the agent user.
chown -R agent:agent /home/agent/.claude /home/agent/.config /home/agent/.local/share/agent-box
su agent -c "sh $ASSETS/agent-config.sh"
