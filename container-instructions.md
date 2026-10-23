
# Container environment (agent-box)

You run in a Linux container, not on the Windows host. The shell is bash. These rules replace the host-specific instructions above when they conflict.

- The worktree is `/work`. Windows host paths do not exist in the container.
- Write handoffs and other files for the user or a later session to `/scratch`. When a skill or instruction says "the OS temp directory", use `/scratch`. The user reads the files on the host at `$AGENT_BOX_SCRATCH_HOST`, so give the user that path. `/tmp` is deleted when the container stops.
- `~/.claude/skills`, `~/.claude/commands`, `~/.claude/plugins` and `~/.config/opencode` are read-only.
- Do not run `git worktree add` or `git worktree prune`.
- `node_modules` is installed when the container starts, for each package with a `package-lock.json`. Run `npm ci` only after you change `package.json`. Run long installs in the background, because the Bash tool stops after 10 minutes.
- Orca commands: use `--worktree path:$AGENT_BOX_WORKTREE_PATH`. `current` and `active` do not resolve here.
