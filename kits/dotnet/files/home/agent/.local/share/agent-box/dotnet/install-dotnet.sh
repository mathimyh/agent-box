#!/bin/sh
# kits/dotnet install step. Runs once as root when the sandbox is created.
# Every step is safe to run again.
set -eu

export DEBIAN_FRONTEND=noninteractive

# .NET needs ICU.
apt-get update
apt-get install -y --no-install-recommends libicu-dev
rm -rf /var/lib/apt/lists/*

# .NET SDK 10. The install script works on every Debian-like image.
if [ ! -x /usr/share/dotnet/dotnet ]; then
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet --no-path
  rm -f /tmp/dotnet-install.sh
fi
ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet

# Environment for every shell, also SSH sessions from Orca. The base kit
# writes its own marked block; this one is separate so both apply.
if ! grep -q 'agent-box-dotnet' /etc/sandbox-persistent.sh 2>/dev/null; then
  cat >> /etc/sandbox-persistent.sh <<'EOF'
# agent-box-dotnet
export DOTNET_ROOT=/usr/share/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
EOF
fi
