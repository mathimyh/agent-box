#!/bin/sh
# Start the authorization plugin first. dockerd refuses every request while
# the plugin is down, so the engine never runs without the policy.
set -e

python3 /usr/local/lib/agent-box-authz.py &
while [ ! -S /run/docker/plugins/agent-box-authz.sock ]; do sleep 0.1; done

# Plain TCP is safe here: the port is only on the private agent-box network.
exec dockerd-entrypoint.sh dockerd \
  --host=tcp://0.0.0.0:2375 --tls=false \
  --authorization-plugin=agent-box-authz
