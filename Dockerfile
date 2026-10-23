# agent-box: sandboxed image for Claude Code and opencode.
# See docs/design.md.

FROM debian:bookworm-slim

ARG NODE_MAJOR=22

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq less openssh-client procps ripgrep socat unzip \
 && curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# .NET SDK, and the Docker CLI for the optional dind sidecar (-Docker).
RUN curl -fsSL https://packages.microsoft.com/config/debian/12/packages-microsoft-prod.deb -o /tmp/ms.deb \
 && dpkg -i /tmp/ms.deb && rm /tmp/ms.deb \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /usr/share/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends dotnet-sdk-10.0 docker-ce-cli \
 && rm -rf /var/lib/apt/lists/*
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
# Linux builds get their own output folders. Windows builds in the same
# worktree leave obj/ and bin/ files that Linux may not touch, and their
# generated sources would compile twice.
ENV BaseIntermediateOutputPath=obj-linux/ BaseOutputPath=bin-linux/ \
    DefaultItemExcludes="obj/**;bin/**"

# uv goes to /usr/local/bin so the home volume does not hide it.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

RUN npm install -g @anthropic-ai/claude-code opencode-ai

# Edits made on Windows send no file events into the container. Dev servers
# must poll to see them. There is no browser to open in the container.
ENV CHOKIDAR_USEPOLLING=true BROWSER=none

# npm uses cached metadata without a registry check, and skips the audit and
# fund calls. A request that hangs fails after 1 minute, not 5. A slow
# npm.intility.com then cannot block an install that the cache can supply.
# See docs/issues/008.
ENV NPM_CONFIG_PREFER_OFFLINE=true NPM_CONFIG_AUDIT=false NPM_CONFIG_FUND=false \
    NPM_CONFIG_FETCH_TIMEOUT=60000

# Orca CLI. The launcher mounts the host's CLI code at /opt/orca-cli. It talks
# to the host runtime over a paired websocket environment, not a local pipe.
RUN printf '#!/bin/sh\nexec node /opt/orca-cli/out/cli/index.js "$@"\n' > /usr/local/bin/orca \
 && chmod 0755 /usr/local/bin/orca

# Bind-mounted files have a foreign owner. Trust every directory.
# Other worktrees have Windows paths and look prunable from Linux. Never
# let gc prune them.
RUN git config --system safe.directory '*' \
 && git config --system gc.worktreePruneExpire never \
 && printf 'obj-linux/\nbin-linux/\n' > /etc/gitignore \
 && git config --system core.excludesFile /etc/gitignore

# Pre-create every bind-mount point under the home volume. Docker creates
# missing mount points as root, which would lock the agent out of its own home.
RUN useradd -m -s /bin/bash agent \
 && mkdir -p /home/agent/.claude/skills /home/agent/.claude/commands \
      /home/agent/.claude/plugins/cache /home/agent/.claude/plugins/marketplaces \
      /home/agent/.config/opencode \
 && chown -R agent:agent /home/agent

# Approved opencode permissions for containers. Managed config has the highest
# priority, so user and project config cannot change it. See docs/design.md.
COPY opencode-managed.json /etc/opencode/opencode.json
# Ignore opencode.json in the repo. The last matching permission rule wins, and
# merged keys keep the position of the layer that added them first. So a
# project config can move "*": "allow" after a deny and cancel it. The flag is
# in the opencode binary but not documented. Verified with opencode 1.19.3.
ENV OPENCODE_DISABLE_PROJECT_CONFIG=1

# Tells the agent that it runs in a container. The entrypoint appends it to
# ~/.claude/CLAUDE.md. opencode reads that file too, through "instructions" in
# the host opencode config.
COPY container-instructions.md /etc/agent-box/container-instructions.md

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# The file may arrive with CRLF from a Windows checkout.
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh && chmod 0755 /usr/local/bin/entrypoint.sh

USER agent
WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
