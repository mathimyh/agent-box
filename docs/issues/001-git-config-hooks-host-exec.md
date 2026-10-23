# 001: An agent can run commands on the host through `.git`

Priority: high. Status: open.

## Problem

The launcher mounts the main repo `.git` directory read-write at `/repo/.git`. Git needs this to write objects and refs. The same directory holds `config` and `hooks/`, and git on the host reads both.

An agent in a container can:

- set `core.fsmonitor = <command>` or `core.hooksPath` in `/repo/.git/config`
- write a script to `/repo/.git/hooks/` (for example `pre-commit` or `post-checkout`)

The next `git status`, commit or checkout on Windows then runs that command on the host, outside the container. The Orca proxy cannot stop this. Not tested yet, but git runs hooks and `core.fsmonitor` by design.

The worktree config (`/repo/.git/worktrees/<name>/config.worktree`) has the same risk if `extensions.worktreeConfig` is on.

## Proposed fix

In `agent-box.ps1`, mount these read-only over the read-write `.git` mount:

- `<mainGit>\config` at `/repo/.git/config:ro`
- `<mainGit>\hooks` at `/repo/.git/hooks:ro`
- `<mainGit>\worktrees\<name>\config.worktree:ro`, if the file exists

## Verify

1. In a container, `echo x >> /repo/.git/config` and `touch /repo/.git/hooks/pre-commit` fail.
2. `git commit`, `git fetch` and `git push` still work in the container.
3. Check that no normal git command in the container must write to `config` (for example `git push -u` writes the upstream to `config`). If it must, find another solution for that command.
