# 002: `GH_TOKEN` has the full scope of the host `gh` login

Priority: high. Status: open.

## Problem

The launcher reads `gh auth token` and gives it to every container. This token has all the access of the user. An agent can push to every repo the user can reach, merge PRs, delete branches and change repo settings.

## Proposed fix

Use a fine-grained personal access token for containers:

- Repository access: only the repos that agents work on.
- Permissions: `contents` write, `pull_requests` write, `issues` read/write if needed, `metadata` read. Nothing else.

The user creates the token in GitHub. The launcher reads it from a source that is not in the worktree (for example Windows Credential Manager) and passes it as `GH_TOKEN`. If no container token is set, the launcher stops with an error, and does not fall back to `gh auth token`.

## Verify

1. `gh pr create` and `git push` work in a container.
2. `gh api` on a repo that is not in the token scope fails.
3. `gh repo edit` fails.
