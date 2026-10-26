

# Sandbox environment (agent-box kit)

You run in a Docker Sandbox on Linux, not on the Windows host. The shell is bash. These rules replace the host-specific instructions above when they conflict.

- Main checkouts are under `/home/agent/repos/<repo>`. Orca worktrees are under `/home/agent/orca/workspaces/<repo>/<worktree>`. Windows host paths do not exist here.
- Write handoffs and other files for the user to `docs/` in the worktree, or to `/home/agent/scratch`. The user reads them with `sbx exec` or over SSH.
- Write temporary files (for example a PR body) to `/home/agent/scratch`, not to `/tmp`.
- `gh` is already authenticated through the sandbox proxy. Do not run `gh auth` commands. They need a permission the sandbox does not give.
- Do not run `git worktree prune`.
- Orca commands: the `orca` CLI sees only this sandbox. Use `--worktree path:/home/agent/orca/workspaces/<repo>/<worktree>`. Host paths do not resolve.
- Build tools: `dotnet` (SDK 10), `oc`, `node`, `npm`, `docker`, `opencode`.
- Docker works, so Testcontainers integration tests run here. Builds write to the normal `bin/` and `obj/` folders.
