# 009: git and gh are slow in containers

Priority: medium. Status: step 1 (`GH_REPO`) done 2026-10-23. Step 3 (a worktree on a Linux file system) is open. See "Result" at the end of this file.

## Problem

`git status` and some `gh` commands are slow in a container. The cause is the Windows bind mount at `/work`, not gh and not the network.

Measured on 2026-10-23 with intility-id (1,571 tracked files). The load average on the host was 15 on 16 CPUs (five agents and their sidecars), so the container numbers are higher than on an idle machine.

| Command | Host | Fresh container, no worktree | Container in `/work` |
|---|---|---|---|
| `gh api /rate_limit` | 0.2 s | 0.5 s | 0.5 s |
| `gh pr list --limit 5` | | | 1.6 s |
| `gh pr list --limit 5 --repo intility/intility-id` | | | 0.6 s |
| `gh pr status` | 3.8 s | | 5.3 s |
| `git status --short` | 0.2 s | | 13 to 19 s (first run 105 s) |
| `git rev-parse`, `git remote -v` | | | 0.3 to 0.5 s each |

- The GitHub API is fast from the container. A fresh container gets the same `gh` times as the host.
- gh runs git to find the repo and the branch. On the bind mount, each small git call takes 0.3 to 0.5 s. This is why `gh pr list` is slow in `/work` and fast with `--repo`.
- `gh pr status` is also slow on the host. Most of its time is the GitHub query.
- `GIT_TRACE_PERFORMANCE` shows that `git status` uses about 9.5 s in "refresh index" and most of the remaining time in the scan for untracked files. Both call `lstat` on each file.
- `stat` on the 1,571 tracked files, without git, takes 20 s. One file access on the mount costs about 10 ms.

Git options do not help, because they do not reduce the number of file accesses:

| Option | `git status --short` |
|---|---|
| none | 13 to 17 s |
| `-uno` (no scan for untracked files) | 8 s |
| `core.checkStat=minimal` | 12 to 15 s |
| `core.trustctime=false` | 13 s |
| `core.untrackedCache=true` | 13 to 14 s |
| `checkStat=minimal` and `untrackedCache=true` | 13 s |

`core.fsmonitor` cannot help. Windows sends no file events into the container (see `design.md`, "Builds and dev servers").

## Proposed design

1. **Set `GH_REPO` in the launcher.** The launcher reads `owner/repo` from the worktree's `origin` remote on the host and passes `-e GH_REPO=<owner/repo>`. gh then does not run git to find the repo. Commands that need the current branch (`gh pr status`, `gh pr create`) still run git, but only for the branch.
2. **Do not change git options.** The test above shows no real gain. `-uno` saves about half of the time, but it hides new files, and agents must see new files before they commit.
3. **The real fix is a worktree on a Linux file system.** This is the Linux-native Orca runtime in WSL that `design.md` describes in "Bind mount speed". It is a larger change. Measure `git status` on a WSL ext4 checkout of intility-id first, to know the gain before the change.

## Verify

1. Start a container for an intility-id worktree. `echo $GH_REPO` shows `intility/intility-id`.
2. In `/work`, `gh pr list --limit 5` takes about the same time as with `--repo` (about 0.6 s).
3. `gh pr status` and `gh pr create --draft` in a throwaway worktree find the correct branch.
4. A worktree without an `origin` remote (or a non-GitHub remote) starts without errors, and `GH_REPO` is not set.

## Result

Verified on 2026-10-23 under Windows PowerShell 5.1.

1. Pass. `GH_REPO` is `intility/intility-id`.
2. Pass. In `/work`, `gh pr list --limit 5` took 0.50 to 0.58 s, and the same command with `--repo` took 0.57 to 0.65 s (3 runs each).
3. Partly. `gh pr status` took 2.5 s and showed the branch `ab-nm-test`. A real draft PR was not created, because it is visible to the team. `gh pr create --draft --dry-run` found the branch and stopped with "you must first push the current branch".
4. Pass. A repo without `origin`, and a repo with a GitLab `origin`, started without errors, and `GH_REPO` was not set. The URL forms `git@github.com:o/r.git`, `ssh://git@github.com/o/r` and `https://github.com/o/r.git` give `o/r`.
