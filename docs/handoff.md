# Handoff: agent-box, next session

Date: 2026-10-26. Read `README.md` and `docs/design.md` first.

## State

- The sandbox path works end to end. A full fanout with the `orca-workers` skill is verified.
- The old launcher path (`agent-box.ps1`, `Dockerfile`, `orca-proxy/`, `dind/`, `orca-agent.*`) and its issues are deleted. Git history keeps them.
- `sbx` 0.49.2 is installed per user with winget (`Docker.sbx`). SSH is on, and the global policy is `balanced`. The GitHub token is a dynamic secret (`sbx secret set github --command "<gh.exe> auth token"`).
- Sandbox `spike` runs with the kit. intility-id is cloned at `/home/agent/repos/intility-id`. The Intility ID MCP server is loaded.
- The secret `intility-glm-5-3` is set. GLM 5.3 Flash is not used any more.
- `agentCmdOverrides` is removed from `orca-data.json`. Claude in local Windows worktrees runs natively on the host.

## Open

1. The kit now has the credential `npm-intility` for `npm.intility.com`, and no flash credential. Recreate the sandbox as `intility-id` (not `spike`) to apply it. Then change the Orca SSH host to `intility-id.sbx`. Not verified yet: `npm ci` in the Portal works through the proxy, and `~/.npmrc` in the sandbox holds no token.
2. If the GLM keys in `~/.config/opencode/opencode.json` on the host are not rotated yet, rotate them. They are in plain text there.
3. The host has 6 stale plugin entries (`ai-go-live` and `mcp-builder` from dadp-skills). Run `claude plugin marketplace update dadp-skills` or uninstall them.
4. Not checked in the sandbox: `packages/access-tree` in intility-id failed `npm ci` with E401 in the old containers. It has its own `.npmrc`.
