# Handoff: agent-box, next session

Date: 2026-10-23 (updated after the orca-workers skill rewrite). Start with the section "Docker Sandboxes kit" in `docs/design.md` and the "Open" list below. Next task: item 4, decide what happens with the old launcher files, or a real fanout with the new skill from inside the sandbox. The rest of `docs/design.md` and the sections after "State" describe the old launcher path, which the sandbox replaces.

## Docker Sandboxes spike (done 2026-10-23, works end to end)

Goal: replace the launcher, `orca-proxy/` and the dind sidecar with Docker Sandboxes (`sbx`) used as an Orca SSH "Run on" target. Worktrees live inside the sandbox. The user accepted that.

What is in place:

- `sbx` 0.49.2 installed per user with winget (`Docker.sbx`). Daemon started, `feature.ssh` on, global policy `balanced`, GitHub token stored as a dynamic secret (`sbx secret set github --command "<gh.exe> auth token"`). The agent only sees a placeholder token.
- Sandbox `spike` (built-in `claude` agent, no workspace mount). intility-id cloned at `/home/agent/repos/intility-id`. `git status` takes 0.03 s there.
- Orca 1.4.237 (updated during the spike). SSH target "Docker Agents" = `spike.sbx`, user `_default_user_`. The repo shows under the same intility-id project as the local worktrees. Current sandbox worktree: `sbx-kit-test` (throwaway, delete when not needed).
- Verified: Claude from the Orca UI runs in the sandbox; Orca status hooks work; a host coordinator Run dispatched a task with `worker-start` and received `worker_done` from the sandbox worker.
- Verified guardrail: the `orca` CLI inside the sandbox sees only the sandbox as `local`. `path:C:/...` selectors do not resolve. On Orca 1.4.218 this was NOT the case: the sandbox created a terminal on Windows. Keep Orca updated.
- `agentCmdOverrides` is removed from `orca-data.json` (backup `.bak-<timestamp>` next to it). Claude in local Windows worktrees now runs natively on the host, not in agent-box.

Rules learned:

- `worker-start` to the sandbox needs `--on "Docker Agents" --worktree path:/home/agent/repos/<wt> --agent claude`. Without `--on` the terminal is not created and the task fails silently.
- Terminal handles differ per host. Use `--environment "Docker Agents"` for `terminal read` and `terminal send` on sandbox terminals. The host-side handle of the same terminal does not count as a "recognized agent".
- From Git Bash, `ssh spike.sbx` fails. Use `C:\Windows\System32\OpenSSH\ssh.exe`.
- The first `worker-start` input was lost because Claude showed a first-run prompt (fullscreen renderer). The second blocked on a permission prompt from the `Bash(gh auth *)` ask rule (from the organization's remote settings, see below). The kit fixes the first and works around the second.

Kit (done and verified 2026-10-23): `sbx-kit/`. See `docs/design.md`, section "Docker Sandboxes kit". The sandbox `spike` was recreated with the kit. A `worker-start` from a host coordinator to Claude Sonnet in the sandbox ran `dotnet`, `oc`, `opencode`, `gh pr list` and `orca status`, and sent `worker_done`. No first-run or permission prompt swallowed the input. The Intility ID MCP server is registered in `sbx mcp` and loaded into `spike`.

Rules learned with the kit:

- `sbx kit add` refuses a kit with `files/`. A kit change means `sbx rm <name>` and `sbx create claude --name <name> --kit .\sbx-kit --static-mcp intility-id`, then clone the repo again. Everything in the sandbox is lost, also Orca's project setup and worktrees there.
- Auto mode refuses `sbx rm`, `sbx create` and `sbx kit add` (classifier: "Create Unsafe Agents"). The user runs them. Run them from the agent-box folder. In a terminal that was open before the winget install, use `$env:LOCALAPPDATA\DockerSandboxes\bin\sbx.exe`.
- After a recreate, Orca reinstalls its daemon in the sandbox at the next connection. The UI shows "connecting" for a minute. Then register the clone and create worktrees through the paired runtime, not the SSH target id, and with `MSYS_NO_PATHCONV=1` in Git Bash:

```
orca project setup-existing-folder --project github:intility/intility-id --host runtime:<environment-id> --path /home/agent/repos/intility-id --kind git
orca worktree create --project intility-id --host runtime:<environment-id> --name <name>
```

  `orca host list` prints the environment id. Worktrees land in `/home/agent/orca/workspaces/<repo>/<name>`.
- Dispatch from outside an Orca terminal: create a shell terminal on the host (`orca terminal create --worktree path:<main checkout>`), `run-create --objective ... --from <handle>`, then `worker-start --spec ... --on "Docker Agents" --worktree path:/home/agent/orca/workspaces/<repo>/<name> --agent claude --model sonnet --from <handle>`. Read results with `orchestration check --terminal <handle>`. `worker-show` and `worker-read` take `--dispatch` and `--environment`, not `--from`.
- The `Bash(gh auth *)` ask rule is from the organization's remote settings in the sandbox, not from Docker's kit. The kit cannot remove it. The sandbox note tells agents not to run `gh auth`.
- The opencode API keys are not set yet: `sbx secret set intility-glm-5-3 -t <key>` and `sbx secret set intility-glm-5-3-flash -t <key>`. Rotate the keys first, see below.

Open:

1. Done 2026-10-23: the kit, verified end to end.
2. Done 2026-10-23: first-run flags and settings merge, verified.
3. Done 2026-10-23: the `orca-workers` skill is rewritten for an orchestrator that runs **inside** the sandbox (the main checkout at `/home/agent/repos/intility-id` also runs on "Docker Agents" now). Checked over SSH: inside, the Orca host is `local`, worktrees are plain `path:` selectors, `worker-start` lists `opencode` as an agent id, and `docker`, `dotnet`, `oc`, `gh`, `opencode` are on PATH. So the skill uses no `--on`, `--environment`, `--host runtime:` or `--from`. Those stay in this file for a coordinator on Windows. The `orca` CLI in a plain SSH session is not on PATH: `~/.orca/cli/bin/orca`.
   - Not verified: `worker-start --agent opencode` in the sandbox, and a full fanout with the new skill text. The skill keeps the shell + `dispatch` recipe for GLM.
   - Known trade-off: all worktrees and the main checkout share one file system and one user. Only the brief stops a worker from touching main or a sibling. Before, each worktree had its own container.
   - GLM workers fail until the opencode secrets are set (item in "Rules learned with the kit").
4. Decide what happens with `agent-box.ps1`, `orca-proxy/` and `dind/`. They are not used by the sandbox path.
5. One sandbox per repo seems the right grain. `spike` is a throwaway name.

## State

agent-box works end to end. Claude Code and opencode run in containers bound to one Orca worktree, with host skills, plugins, MCP servers and `GH_TOKEN`. Logins and MCP OAuth tokens for both agents are in the Docker volume `agent-box-home`. Orca can start a container with:

```powershell
orca terminal create --worktree active --command "powershell -NoProfile -ExecutionPolicy Bypass -File $HOME\Documents\agent-box\agent-box.ps1 -Agent claude"
```

Test worktree used so far: `C:\Users\aa1359\orca\workspaces\intility-id\978-nuget-lockfiles`.

## Task 1: Orca pairing from inside a container (done 2026-10-19)

Done. See `docs/design.md`, section "Orca CLI". Summary:

- The CLI is plain Node code. The launcher stages it in `.staging/orca-cli/` and the image has an `orca` wrapper. No Linux binary was needed.
- The container was paired with the desktop runtime over `host.docker.internal:6768` as `host`. This direct pairing is replaced by the Orca proxy (see below) and removed.
- Verified inside the container: `orca status`, `orca orchestration check`, `orca worktree list`, `orca terminal list --worktree path:...`.
- `orca orchestration send` works when Orca started the launcher in one of its terminals. The launcher forwards `ORCA_TERMINAL_HANDLE`. Verified 2026-10-20 with `worker_done`.
- `current` and `active` never resolve on a remote runtime. Agents must use `--worktree path:$AGENT_BOX_WORKTREE_PATH`. Task 2 must tell the spawned agent this.

## Task 2: switch the skills to containers (done 2026-10-20)

- `worktree-fanout` now starts every worker with the launcher. Flow: `worktree create` without `--agent`, get the shell handle from `terminal list`, seed `.agents/`, `terminal send` the launcher into that shell, then `worker-start --terminal <handle>` (Claude) or `dispatch` (opencode). The `orchestration` skill had no spawn command, so it did not change.
- The launcher has a new `-Model` parameter, because `worker-start` cannot combine `--model` with `--terminal`.
- The launcher now stops with an error if the container for the worktree is already running. Before, it ran `docker rm -f` and stopped the running agent.
- Verified: `worker-start --terminal` delivered a task to Claude in a container, and the worker sent `worker_done` back. Also verified the new-worktree recipe up to a running agent, and the collision error.
- Coordinator commands need a sender terminal. From outside an Orca terminal, pass `--from <handle>` of a plain shell terminal you own.

## Spike before Task 3 (done 2026-10-20)

Task 3 picked #976 (keycloak-api add/remove one redirect URI). The container could not verify it, so the image and launcher got these changes. See `docs/design.md`, sections "Docker sidecar" and "Builds and dev servers".

- .NET 10 SDK and Docker CLI in the image.
- `-Docker`: a privileged dind sidecar with an authorization plugin that refuses host access. The user accepted this risk on 2026-10-20 instead of mounting the host socket.
- `-Port` and `-Volume` for dev servers and `node_modules`.
- npm login for `npm.intility.com` is in the home volume.

Decisions for #976, already made with the user:
- Serialize the read-modify-write per client with a Postgres advisory lock (`pg_advisory_xact_lock`), not an in-process lock. Prod runs 2 replicas.
- Model: GLM 5.3 (opencode), per the worktree-fanout model bar. This also tests the opencode container path for the first time.
- PR #987 (#977) is merged, so there is no collision.

## Task 3: start real work in containers (done 2026-10-20)

#976 is done and merged. Its `-dind` sidecar is gone.

## Orca proxy (done 2026-10-20)

A direct Orca pairing let a container run commands on Windows: one `orca terminal create` call from a container created a file in the Windows home folder. Fixed with `orca-proxy/`. See `docs/design.md`, section "Orca proxy".

- Containers pair with the proxy (`ORCA_ENVIRONMENT=proxy`). The proxy ends Orca's end-to-end encryption, allows only `status.get`, `terminal.resolveActive` and `orchestration.send/check/reply/inbox/dispatchShow/taskList`, and forwards these with the real pairing.
- The real pairing is only in the volume `agent-box-orca-proxy`. The old `host` pairing is removed from the home volume, and the user revoked it in Orca.
- The launcher starts the proxy on demand. It has no restart policy: auto mode refused `--restart unless-stopped`, and the user accepted that.
- Verified: auto-pairing, `check`, `send`, `inbox` pass; `terminal.create` and `worktree.list` are refused.
- Verified 2026-10-20: a full worktree-fanout round trip through the proxy (throwaway worktree, Claude Sonnet in a container, `worker-start --terminal`, `worker_done` received). The worker used only `status.get` and `orchestration.send`. No method was refused. A missing method shows as `DENY <method>` in `docker logs agent-box-orca-proxy`.
- `worker-start` returns `stage: input_accepted` on success. The skill now accepts it as well as `ready`.
- `orchestration check` and `worker-release` reject `--from`. `check` takes `--terminal <handle>` for the coordinator mailbox. Run, task and worker-start commands need `--from`, and a Run is bound to that sender terminal.
- The coordinator stays on the host. The user agreed to start it without `--dangerously-skip-permissions`, because worker messages are untrusted input.

## Next steps

1. Done 2026-10-20: full worker round trip through the proxy. See "Orca proxy".
2. Done 2026-10-20: Claude agents started by Orca (UI, `worktree create --agent`, `worker-start --agent --model`) in `~\orca\workspaces\` run in agent-box. See `docs/design.md`, section "Orca wiring", also for how to change the setting (close Orca, edit the JSON, click "Use JSON"). worktree-fanout starts Claude workers natively again. GLM and `-Docker` workers still use the launcher recipe. `probe\` is deleted.
   - Open: add opencode to the override. Use the same wrapper (`orca-agent.cmd opencode`). Check what args Orca appends for opencode first.
   - Open: Orca's status hooks do not work in containers, so the sidebar shows no working or idle status for those agents.
   - Not verified: Claude from the Orca UI in a main checkout (expected on the host), and Orca's AI commit messages through the wrapper.
   - The user's worktree `intility-id/probe-test` is still there, with Claude running in `agent-box-probe-test`. Remove it when it is not needed.
   - Done 2026-10-20: approved opencode permissions are in the image as managed config, and project config is turned off. See `docs/design.md`, section "opencode permissions". Done 2026-10-20: the Intility ID MCP write tools are `ask`, and the read tools are allowed. A live prompt is not tested yet.
3. **Terminals opened from the Orca UI run on the host.** A `$PROFILE` snippet that joins the worktree's running container with `-Shell` was proposed. The user has not decided.
4. Done 2026-10-20: agents know that they run in a container. The note is in `container-instructions.md`, and handoffs go to the `/scratch` mount. See `docs/design.md`, section "Mounts and environment".
5. Done 2026-10-20: the skill `worktree-fanout` is renamed to `orca-workers`, because agents used `orca-cli` or `orchestration` to start workers and did not know about containers. Its description now claims every worker start, also for one worker. Earlier entries in this file use the old name.
6. Later: a coordinator container with a wider allow-list, if useful.

## Open items not to forget

- Open issues are in `docs/issues/`, one file each. Start with 001 (git config and hooks let an agent run commands on the host).
- 008: done 2026-10-23. The launcher finds each `package-lock.json` and adds a `node_modules` volume. The entrypoint runs `npm ci` before the agent starts when the lock file changed. The image sets npm defaults (`prefer-offline`, a 1-minute fetch timeout). `agent-box.ps1 -Clean` removes the volumes of removed worktrees. See `docs/design.md`, "Builds and dev servers".
  - Open: `packages/access-tree` in intility-id fails `npm ci` with E401 at each start. The Portal uses the same registry and installs. The package has its own `.npmrc`, which was not read. Check its auth setup on the host.
  - Remove by hand: `agent-box-978-nuget-lockfiles-services-intility-id-portal-node_modules`. It has no label, so `-Clean` ignores it.
  - Running agent containers that started before 2026-10-23 use the old image. They get the new behavior at their next start.
  - `-NoNpmInstall` skips the install at start. The volumes are still added. Agents that Orca starts cannot use it, because `orca-agent.ps1` passes no launcher parameters. Open: if those agents must skip the install too, add an environment variable that `orca-agent.ps1` reads. The user has not decided.
  - Not measured: many worktrees that start at the same time. The first start of an intility-id worktree installs 8 packages (about 45 s alone). With 8 at once, expect a few minutes each. Risk: `worker-start --agent claude` waits for the agent, and the agent starts only after the install. It is not known if Orca stops waiting before that. The user chose not to test it now.
- 009: step 1 done 2026-10-23. The launcher sets `GH_REPO` from `origin`, so `gh pr list` in `/work` takes 0.5 s, not 1.6 s. `git status` is still 13 to 19 s. The real fix (a worktree on a Linux file system) is open.

- Two API keys sit in plain text in `~/.config/opencode/opencode.json` lines 71 and 84. Rotate them.
- The host has 6 stale plugin entries (`ai-go-live` and `mcp-builder` from dadp-skills). Run `claude plugin marketplace update dadp-skills` or uninstall them.
- Never run `git worktree prune` or `git worktree add` inside a container.

## Notes for tests

- Do not run `agent-box.ps1 -Build` while other agents work. It also removes the Orca proxy container, which the running agents use. To rebuild only the agent image, run `docker build -t agent-box:local .` in the agent-box folder.
- Git Bash changes arguments that start with `/` into Windows paths. This changes `--text '/exit'` and `--filter name=^/<container>$`. Set `MSYS_NO_PATHCONV=1` first.
- Auto mode refuses `docker exec` into agent containers, also your own test container. To read a volume, mount it read-only in a new container. To stop a test agent, send `/exit` with `orca terminal send`.
- Windows does not let you delete or move a folder that a running container has as a bind mount.
