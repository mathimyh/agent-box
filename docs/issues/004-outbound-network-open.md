# 004: Outbound network access is not limited

Priority: medium. Do this after 001, 002 and 003. Status: open.

## Problem

Containers use the default bridge network with full outbound access. Agents need APIs (Claude, opencode providers, GitHub, MCP servers, npm and NuGet feeds). But a prompt injection in an issue, a web page or a dependency can make an agent send tokens to any host.

## Proposed fix

Put containers on an internal Docker network. Add an egress proxy container (for example Squid or a small allowlist proxy) as the only way out. Set `HTTP_PROXY` and `HTTPS_PROXY` in the agent container. Allow only the domains in a list in the repo.

## Open questions

- Which domains do the agents need? Log them for some days before you turn on the block.
- Do .NET, npm, Testcontainers and the dind sidecar respect the proxy variables?

## Verify

1. A normal worker run (build, tests, PR) works.
2. `curl https://example.com` in a container fails.
