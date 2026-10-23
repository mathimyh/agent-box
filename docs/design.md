# agent-box: containerized agents for Orca worktrees

Status: built and verified for Claude Code and opencode on 2026-10-19, including Orca terminal launch, MCP OAuth for both agents, and the Orca CLI paired with the host runtime from inside the container.

Location: `C:\Users\aa1359\Documents\agent-box\`. Personal tooling, not a git repo. Move to a repo only when teammates need the same image or when CI should build and push it.

## Goal

Run every coding agent (Claude Code, opencode) inside its own container. Keep the agent limited to one git worktree. Give the agent the user's skills, MCP servers, and GitHub access. Make it usable from Orca with no change to how Orca manages worktrees.

## Requirements

- Each agent runs in a container. One container per worktree.
- Agents are Claude Code and opencode.
- The agent has access to the global skills and plugins in `~/.claude` and `~/.config/opencode`.
- The agent has access to the configured MCP servers.
- The agent can use `gh` with the user's token.
- Orca starts the agent in an Orca-managed worktree.
- The main reason for containers is a safety sandbox. The agent must not be able to change host configuration or read host secrets from files.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Container runtime | Docker Desktop first, `wslc` later | Docker Desktop is installed. WSL containers use the same image and the same flags. The switch is one line in the launcher. |
| Worktree location | Where Orca puts them, bind-mounted | Orca on Windows keeps its worktrees in `C:\Users\aa1359\orca\workspaces\<repo>\<name>`. The main checkout is in `Documents\repos\<repo>`. One Orca runtime stays. |
| Orca integration | Launcher script as the terminal command | Orca does not need to know about Docker. |
| Agent state | One shared Docker volume for `/home/agent` | Log in once. All containers reuse the login and the MCP OAuth tokens. |
| Host config | Sanitized copies and read-only bind mounts | The agent can read skills and settings but cannot change them on the host. |
| Secrets | Environment variables only | No credential file enters the image or a volume from the host. |

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Image `agent-box:local`. Debian, git, gh, Node 22, .NET 10 SDK, Docker CLI, Claude Code, opencode, uv. Non-root user `agent`. |
| `dind/` | Image `agent-box-dind:local` for `-Docker`. `docker:29-dind` with the authorization plugin `authz.py`. |
| `orca-proxy/` | Image `agent-box-orca-proxy:local`. Filters the Orca runtime methods that containers can call. See "Orca proxy". |
| `entrypoint.sh` | Copies staged config into the home volume, sets git options, installs `node_modules` when a lock file changed, starts the agent. |
| `agent-box.ps1` | Launcher. Stages config, resolves the worktree, runs the container. |
| `opencode-managed.json` | Approved opencode permissions. Copied into the image as `/etc/opencode/opencode.json`. See "opencode permissions". |
| `orca-agent.cmd`, `orca-agent.ps1` | Orca agent command override. Sends agents in Orca worktrees to the launcher. See "Orca wiring". |
| `.staging/<container>/` | Generated per run. Sanitized host config. Mounted read-only at `/host-config`. |
| `.staging/orca-cli/` | Copy of the host Orca CLI code and its npm dependencies. Refreshed when the Orca version changes. Mounted read-only at `/opt/orca-cli`. |

## Launcher

`agent-box.ps1` works in Windows PowerShell 5.1 and pwsh 7.

| Parameter | Meaning |
|---|---|
| `-Agent claude\|opencode` | Which agent to start. Default `claude`. |
| `-Worktree <path>` | Worktree directory. Default: current directory. |
| `-Prompt <text>` | Initial prompt for the agent. |
| `-Model <id>` | Model for the agent, passed as `--model`. Orca cannot set the model of a worker it did not start. |
| `-AgentArgs <arg>[,<arg>]` | More args for the agent, passed through as they are. `orca-agent.ps1` uses it for the args that Orca appends. |
| `-Shell` | Start bash instead of an agent. If the agent container of the worktree runs, open bash in it (`docker exec`) instead. |
| `-Command <text>` | Run one bash command non-interactively and exit. For checks and scripts. |
| `-Build` | Rebuild the image. The launcher also builds when the image is missing. |
| `-Docker` | Start a private Docker engine (dind sidecar) for Testcontainers. See "Docker sidecar". |
| `-Port <n>[,<n>]` | Publish these ports on host `127.0.0.1` with the same number. For dev servers. |
| `-Volume <path>[,<path>]` | Put more worktree-relative folders (for example `bin-linux`) in a named volume per worktree. `node_modules` folders get a volume automatically. See "Builds and dev servers". |
| `-NoNpmInstall` | Do not run `npm ci` at start. The `node_modules` volumes are still added. Agents that Orca starts cannot use this parameter, because `orca-agent.ps1` passes no launcher parameters. |
| `-Clean` | Remove the dependency volumes of worktrees that no longer exist, then exit. A volume that a container uses is kept. Run it by hand, for example after `orca worktree rm`. |
| `-OAuthRelay` | Publish port 19876 and relay it to loopback inside the container. Needed once for `opencode mcp auth`. Only one container can hold the port at a time. |

Set `AGENT_BOX_DEBUG=1` to print the full `docker run` argument list.

The container name is `agent-box-<worktree folder>`. One worktree holds one container. If a container with that name is running, the launcher stops with an error. It does not replace the container, because that stops the agent in it.

## Docker sidecar

Test suites that use Testcontainers need a Docker engine. The agent must not get the host engine: one `docker run -v C:\:/host` would give it every host file.

With `-Docker`, the launcher starts `agent-box-dind:local` (built from `dind/`) as `<container>-dind`. The sidecar is on a private network with the agent container. The agent gets `DOCKER_HOST=tcp://dind:2375`. Image layers are kept in the volume `<container>-dind`. The launcher removes the sidecar and the network when the agent exits. If the terminal is killed, the next start removes them.

The sidecar must run `--privileged`. Without a guard, the agent could start a privileged container inside it and escape to the Docker Desktop VM. The authorization plugin `dind/authz.py` runs inside the sidecar and refuses:

- privileged containers and privileged exec
- added capabilities, devices, custom runtimes, cgroup parents, sysctls, and security options other than `no-new-privileges`
- bind mounts (named volumes and tmpfs are allowed)
- host PID, network, IPC, UTS, user and cgroup namespaces
- volumes and networks with driver options
- plugins, builds, and swarm endpoints

dockerd refuses every request while the plugin is down. Testcontainers' cleanup container Ryuk mounts the socket, so the launcher sets `TESTCONTAINERS_RYUK_DISABLED=true`. Removing the sidecar removes the test containers.

Docker Desktop Enhanced Container Isolation would remove the need for the privileged sidecar. It is not enabled on this machine.

## Builds and dev servers

- .NET builds in the container write to `bin-linux/` and `obj-linux/`, and skip `bin/` and `obj/`. Linux may not set timestamps on files that a Windows build created, and the Windows generated sources would compile twice. Container git ignores the new folders through `/etc/gitignore`. Host git shows them as untracked unless the host global gitignore lists them.
- Packages from `npm.intility.com` need a login. Do it once in `-Shell` with `npm login --registry https://npm.intility.com`. The token stays in the home volume.
- Each `node_modules` folder is in a named volume per worktree. Windows and Linux packages have different native binaries. The volume is also faster than the bind mount. The launcher finds each `package-lock.json` at most 3 folder levels below the worktree. It skips `node_modules` and folders whose name starts with a dot. For each package, it adds the volume `<container>-<package path>-node_modules` with the label `agent-box.worktree=<worktree path>`, and passes the package list in `AGENT_BOX_NPM_PACKAGES`. Agents that Orca starts get the volumes too, because the launcher needs no parameter for them.
- Before the agent starts, the entrypoint compares the SHA-256 of each `package-lock.json` with the marker file `node_modules/.agent-box-lock-sha256` in the volume. If the marker is missing or different, the entrypoint runs `npm ci` in that package and then writes the marker. The agent starts after the installs, so the agent and the entrypoint never run npm at the same time. If `npm ci` fails, the entrypoint prints the error, writes no marker and starts the agent. The next start tries again. A manual `npm ci` in the container also removes the marker, so the next start installs again.
- The first start of an intility-id worktree installs 8 packages in about 45 s. A start with no lock file change installs nothing. With `-NoNpmInstall`, the launcher does not set `AGENT_BOX_NPM_PACKAGES`, so the entrypoint installs nothing. The volumes are still added.
- The image sets `NPM_CONFIG_PREFER_OFFLINE=true`, `NPM_CONFIG_AUDIT=false`, `NPM_CONFIG_FUND=false` and `NPM_CONFIG_FETCH_TIMEOUT=60000`. npm uses cached metadata without a registry check, and a request that hangs fails after 1 minute, not 5. Thus a slow `npm.intility.com` cannot stop an install that the cache can supply. See `docs/issues/008-node-modules-per-worktree.md`.
- The launcher never removes volumes when it starts. Run `agent-box.ps1 -Clean` to remove the volumes of removed worktrees. `-Clean` reads the `agent-box.worktree` label, so it ignores volumes without the label, for example volumes from before 2026-10-23. Remove those by hand with `docker volume rm`.
- Edits made on Windows send no file events into the container. The image sets `CHOKIDAR_USEPOLLING=true`, so Vite polls. The image also sets `BROWSER=none`.
- A dev server must listen on `0.0.0.0` in the container, for example `npm run dev -- --host 0.0.0.0`, and the launcher must publish its port with `-Port`.

Steps the launcher performs:

1. Resolve the worktree. Read its `.git` file to find the main repo `.git` directory and the worktree name.
2. Stage sanitized config in `.staging/<container>/claude/`:
   - `settings.json` without `hooks` and `statusLine` (they call PowerShell and Orca hooks that do not exist in Linux).
   - `CLAUDE.md`.
   - `mcp.json` with only the `mcpServers` object from `~/.claude.json`.
   - `installed_plugins.json` and `known_marketplaces.json` with `C:\Users\<user>\.claude` rewritten to `/home/agent/.claude`.
3. Stage the Orca CLI in `.staging/orca-cli/` when the staged version differs from the installed Orca version.
4. Read the GitHub token with `gh auth token` into the process environment.
5. Run `docker run --rm` with the mounts and environment below.

### Mounts and environment

| Host | Container | Mode |
|---|---|---|
| Worktree directory | `/work` | rw |
| Main repo `.git` directory | `/repo/.git` | rw. Git needs to write objects and refs. The main working tree is not mounted. |
| volume `agent-box-home` | `/home/agent` | rw. Claude login, MCP OAuth tokens, history, caches. |
| `.staging/<container>` | `/host-config` | ro |
| `.staging/orca-cli` | `/opt/orca-cli` | ro |
| `~/.claude/skills` | `/home/agent/.claude/skills` | ro |
| `~/.claude/commands` | `/home/agent/.claude/commands` | ro |
| `~/.claude/plugins/cache` | `/home/agent/.claude/plugins/cache` | ro |
| `~/.claude/plugins/marketplaces` | `/home/agent/.claude/plugins/marketplaces` | ro |
| `~/.config/opencode` | `/home/agent/.config/opencode` | ro |
| `agent-box\scratch\<container>` | `/scratch` | rw. Handoffs and other files the user reads on the host. |
| volume `<container>-<path>` | `/work/<path>` | rw. One for each `node_modules` folder and each `-Volume` folder. |

The entrypoint appends `container-instructions.md` to `~/.claude/CLAUDE.md` in the container. The note tells the agent that it runs in a container and that it must write handoffs to `/scratch`. opencode reads the same file, because the host opencode config lists `~/.claude/CLAUDE.md` in `instructions`. If you remove that entry, add the note to `opencode-managed.json`.

`TMPDIR` stays `/tmp`. .NET and other tools create Unix sockets in `TMPDIR`, and Unix sockets do not work on a Windows bind mount.

| Variable | Value |
|---|---|
| `GH_TOKEN` | From `gh auth token` at launch. The entrypoint runs `gh auth setup-git` so `git push` over https uses it. |
| `GIT_DIR` | `/repo/.git/worktrees/<name>` |
| `GIT_WORK_TREE` | `/work` |
| `GIT_AUTOCRLF` | The host `core.autocrlf` value, applied inside the container. |
| `GH_REPO` | `owner/repo` from the worktree's `origin` remote, read on the host. Not set when `origin` is missing or is not on github.com. With it, gh does not run git to find the repo. Each git call is slow on the bind mount. See `docs/issues/009-git-gh-slow-on-bind-mount.md`. |
| `AGENT_BOX_NPM_PACKAGES` | The worktree-relative package folders with a `package-lock.json`, separated by `:`. `.` is the worktree itself. The entrypoint installs them. |
| `ORCA_CLI_COMMAND` | `orca`. The Orca skills use this executable when the variable is set. |
| `ORCA_ENVIRONMENT` | `proxy`. The name of the pairing with the Orca proxy in the home volume. |
| `AGENT_BOX_ORCA_LINK` | The proxy pairing link. The entrypoint pairs with it once, then unsets it before the agent starts. |
| `AGENT_BOX_SCRATCH_HOST` | The Windows path of the scratch folder. The agent gives this path to the user. |
| `AGENT_BOX_WORKTREE_PATH` | The Windows path of the worktree with forward slashes. Use it as `--worktree path:$AGENT_BOX_WORKTREE_PATH`. |
| `ORCA_TERMINAL_HANDLE`, `ORCA_PANE_KEY`, `ORCA_WORKTREE_ID`, `ORCA_WORKSPACE_ID` | Forwarded from the launcher's environment when Orca set them. They give orchestration commands their sender identity. |

Security flags: `--cap-drop ALL`, `--security-opt no-new-privileges`, `--memory 8g`, `--cpus 4`. Default bridge network, because the agent needs the Claude API, HTTP MCP servers, and GitHub.

Claude Code starts with `--mcp-config /host-config/claude/mcp.json`.

## Orca wiring

Orca has a hidden setting `agentCmdOverrides` (no UI field). It is a map from agent id to a base command. Orca appends its own args to that command. It is set for Claude:

```json
"agentCmdOverrides": {"claude": "C:\\Users\\aa1359\\Documents\\agent-box\\orca-agent.cmd claude"}
```

`orca-agent.ps1` looks at the working directory:

- Under `~\orca\workspaces\`: start the agent with the launcher. Orca's args go in `-AgentArgs`.
- All other directories: start the agent on the host. This covers Orca's `--version` check (Orca runs it from its install folder at start) and agents in main checkouts, such as the coordinator.

So the Orca UI, `worktree create --agent claude` and `orchestration worker-start --agent claude --model <id>` all start Claude in a container. Orca passes `--dangerously-skip-permissions` and, from `worker-start`, `--model`. Orca also sets `ORCA_TERMINAL_HANDLE` and `ORCA_WORKTREE_ID`, and the launcher forwards them.

If the launcher fails (for example, the container for the worktree already runs), the wrapper shows the error and waits for Enter. Without this, Orca closes the pane and the error is lost.

Orca also reads the override for its AI commit messages. Not verified: what that call does through the wrapper.

To change the setting:

1. Close Orca. On close, Orca writes `%APPDATA%\orca\profiles\local-default\orca-data.json` and `profile-state.db` (SQLite) at the same time.
2. Back up `orca-data.json`, then change only the `agentCmdOverrides` value. The file is one long line, so make a scripted exact replacement and check that the result is valid JSON. Build Windows paths without backslash literals, because the shell removes them.
3. Start Orca. Orca sees that the JSON and SQLite copies do not match. Click **Use JSON**. Orca archives both copies.

Not covered: Orca's agent status hooks (`ORCA_AGENT_HOOK_*`, `~/.orca/agent-hooks/claude-hook.cmd`). The launcher removes host hooks from the container settings, so the Orca sidebar does not show working or idle status for agents in containers. opencode is not set in the override yet.

## opencode permissions

Enterprise policy blocks `--dangerously-skip-permissions` for Claude, so Claude asks for permissions as usual. opencode has no such policy. The approved permissions for opencode in a container are in `opencode-managed.json`.

- The image copies the file to `/etc/opencode/opencode.json`. This is opencode's managed config on Linux. It has a higher priority than the user config and the project config.
- The image sets `OPENCODE_DISABLE_PROJECT_CONFIG=1`. The last matching permission rule wins, and a merged key keeps the position of the layer that added it first. Without the flag, an `opencode.json` in the repo could put a key such as `*.env` before `*` and so cancel the deny. The flag is in the opencode binary but not documented. Verified with opencode 1.19.3 and `opencode debug config`. The `.opencode` folder in intility-id holds only a `node_modules` cache, so nothing is lost.
- The read denies stop accidental reads. They are not a security boundary, because `bash` is `allow`. The boundary is the container: only the worktree, the staged config and the home volume are in it. Your host `~/.config/opencode` is mounted read-only, so its API keys are readable in the container.
- `"*": "allow"` also allows all MCP tools. The Intility ID tools (`intility-id_*`) are set to `ask`, and only the read tools (`get`, `list`, `check`, `batch_check`, `describe`, `preview_delete`) are allowed. A new write tool on the server therefore asks before it runs. The write tools act with your identity in dev. Rule order verified with `opencode debug agent build`.
- `external_directory` is `ask`, but `/scratch/**` is `allow`. Handoffs and other files for the user go there, so a prompt for each file is only noise.

## MCP servers

- claude.ai connectors (Bifrost, Lucid, Microsoft Learn, Adobe) follow the Claude login. No extra setup.
- `intility-id` is an HTTP MCP server with OAuth. Authenticate once per agent. The tokens persist in the home volume.
  - Claude Code shows a URL and accepts the code pasted back. No extra setup.
  - opencode waits for a browser redirect to `127.0.0.1:19876`, bound to loopback inside the container. Start a container with `-Shell -OAuthRelay`, run `opencode mcp auth intility-id`, open the printed URL on the host. The entrypoint runs a `socat` relay from the container interface to loopback so the redirect arrives.
- The `github` plugin MCP server uses a token in a header. Keep that token valid on the host first.

## First run

1. Start a container with `-Agent claude`. Complete the Claude login in the terminal. The login persists in the home volume.
2. Start a container with `-Agent opencode`. Run `opencode auth login`, choose `Other`, and type the provider id from `opencode.json` if that provider has no key in the config.
3. Authenticate the `intility-id` MCP server in Claude when it asks.
4. Authenticate it in opencode from a `-Shell -OAuthRelay` container with `opencode mcp auth intility-id`.
5. Pair the Orca proxy with the host runtime. See "Orca proxy" below.

## Known problems and their solutions

### Git worktree paths

A worktree's `.git` file contains an absolute Windows path. Inside Linux that path does not exist. The launcher solves this with `GIT_DIR` and `GIT_WORK_TREE`. Git resolves the common directory through the relative `commondir` file. Status, fetch, commit, and push work normally.

Do not run `git worktree repair` inside the container. It rewrites the shared file and breaks the worktree for Orca on Windows.

### Other worktrees look prunable

`git worktree list` inside the container marks every other worktree as `prunable`, because their Windows paths do not resolve. The image sets `gc.worktreePruneExpire never`, so automatic gc never prunes them. An explicit `git worktree prune` inside the container still deletes the metadata for all worktrees. Tell agents not to run it. Do not create worktrees from inside the container either. They would get Linux paths that Orca cannot use.

### Read-only plugin cache

Plugins that download binaries into their cache at runtime (for example a language server) fail inside the container because the cache is read-only. Install such plugins on the host first so the binary is already in the cache.

### Bind mount speed

Docker Desktop on the WSL2 backend reads Windows files slowly. Git operations and file edits are acceptable. Package installs and builds are slow.

Solution when it hurts: mount a named volume per worktree over `node_modules`, `bin`, and `obj`. `node_modules` gets a volume automatically (see "Builds and dev servers").

If that is not enough, move to a Linux-native Orca runtime: run `orca serve` in a WSL distribution and pair the Windows app with `orca environment add`. This is a larger change and is not the first step.

### Orca CLI

Orca ships no Linux binary, but the CLI is plain Node code in `resources\app.asar.unpacked\out\cli` with shared code in `out\shared`. It needs four npm packages: `zod`, `ws`, `tweetnacl`, `yaml`. They sit in `resources\node_modules`. The launcher copies all of it to `.staging/orca-cli/` and the image has `/usr/local/bin/orca`, a two-line wrapper that runs it with the container's Node 22. The `@xterm` packages that some terminal commands require are not in `resources\node_modules`. No command used so far needs them.

On the host, the CLI talks to the app over a named pipe. The container cannot use that pipe. The desktop app also listens on a websocket at `127.0.0.1:6768`, and Docker Desktop forwards `host.docker.internal` to the host loopback. So the container talks to the host runtime as a remote environment, through the Orca proxy below.

Every container gets `ORCA_ENVIRONMENT=proxy`, so every `orca` command goes through the proxy. Limits on a remote runtime:

- The `current` and `active` shortcuts do not resolve. Use `--worktree path:$AGENT_BOX_WORKTREE_PATH` or another explicit selector.
- Orchestration `send` and `ask` need a sender identity. The launcher forwards `ORCA_TERMINAL_HANDLE` from its own environment, so this works when Orca started the launcher in one of its terminals. It does not work from a plain PowerShell window.
- The CLI version must match the app. The launcher re-stages the CLI when the app version changes.

### Orca proxy

A paired Orca client can call every runtime method. `terminal.create` and `terminal.send` run commands in Orca terminals, and those run on Windows. On 2026-10-20 a container with a direct pairing created a file in the Windows home folder with one `orca terminal create` call. So a direct pairing goes around the container isolation.

Orca has no per-device method limit for runtime pairings, and it encrypts every frame end to end (NaCl box), so a network filter cannot see the method names. `orca-proxy/proxy.js` ends the encryption itself:

- Containers pair with the proxy, which has its own key and token. The proxy decrypts each request and checks the method against an allow-list.
- Allowed requests go to Orca over a separate connection with the real pairing. Refused requests get a `forbidden` error.
- The real pairing is only in the `agent-box-orca-proxy` volume. Only the proxy container mounts it.
- Allowed: `status.get`, `terminal.resolveActive`, and `orchestration.send`, `check`, `reply`, `inbox`, `dispatchShow`, `taskList`. Every other method is refused, for example `terminal.*`, `worktree.*`, `browser.*`, and `orchestration.dispatch`.
- `orchestration.send` cannot type into a shell. Orca stores the message and types only a fixed pointer ("run orca orchestration inbox") into an idle agent, never into a plain shell. The message text still reaches the coordinator agent, so treat worker messages as untrusted input.

The launcher builds the image, starts the proxy container (`127.0.0.1:6769`) when it is not running, and passes the proxy pairing link to the entrypoint. The proxy logs every allowed and refused method: `docker logs agent-box-orca-proxy`.

Pair the proxy once. Run the command yourself, because the link holds a device token:

1. In Orca: Settings > Remote Orca Servers > Share this host. Choose Custom address, enter `host.docker.internal:6768`, click Generate Access Link. Copy the link under "Pair another Orca client".
2. `docker run --rm -v agent-box-orca-proxy:/data agent-box-orca-proxy:local node proxy.js init "<link>" ws://host.docker.internal:6769`

If you pair the proxy again, its own token changes. Then remove the old container pairing from a `-Shell` container: `orca environment rm --environment proxy`. The next start pairs again.

Never add a direct pairing (`orca environment add` with an Orca link) inside a container. It goes around the proxy.

## Verified on 2026-10-19

Run against the Orca worktree `intility-id/978-nuget-lockfiles`:

- Container runs as `agent`, not root.
- `git status`, `git log`, and `git fetch` match the host and use the correct branch.
- `gh auth status` and `gh pr list` work through `GH_TOKEN`.
- Claude Code 2.1.303, opencode 1.19.3, uv 0.13.1 present.
- 21 skills and 4 plugin marketplaces visible.
- `/work` is writable. `~/.claude/skills` is read-only.

Also verified the same day: Claude login, Claude plugins load (same 20 of 26 as the host; the 6 failures are stale host entries), opencode starts with the default provider, `intility-id` MCP OAuth in both Claude and opencode, Orca `terminal create` starts the launcher in a worktree.

Orca CLI, same day: `orca environment add` with a pairing link for `host.docker.internal:6768` succeeded inside the container. `orca status`, `orca orchestration check`, `orca worktree list`, `orca terminal list --worktree path:...`, and `orca agent-context` all answered from the host runtime, through the launcher, under Windows PowerShell 5.1.

## Verified on 2026-10-20

- `orca orchestration worker-start --terminal` delivered a task to Claude in a container. The worker sent `worker_done` back.
- A second launch for a running worktree stops with an error. The first container keeps running.
- With `-Docker`: the full keycloak-api suite passed in the container (325 tests, Testcontainers Postgres in the sidecar, about 3 minutes including the first image pull). From the agent container, a plain `docker run` works, and `--privileged` and `-v /:/host` are refused. A matrix of 17 cases against the sidecar gave the expected result for each.
- The Portal: `npm ci` into a `node_modules` volume took 2 minutes 42 seconds. `npm run dev -- --host 0.0.0.0` with `-Port 3003` answered on host `localhost:3003`. A Windows edit gave `hmr update` with polling, and no event without it.
- The launcher runs under Windows PowerShell 5.1.

- orca-workers (then called worktree-fanout) through the Orca proxy: `worker-start --terminal` to `worker_done`. The worker used only `status.get` and `orchestration.send`.
- `agentCmdOverrides` with `orca-agent.cmd`: a Claude agent started from the Orca UI ran in a container with `--dangerously-skip-permissions`. `worker-start --agent claude --model sonnet` ran in a container with `--model sonnet` and sent `worker_done`. `orca-agent.cmd claude --version` from the Orca install folder ran on the host.

Not yet verified: the Portal login in a browser against the containerized dev server. Claude started from the Orca UI in a main checkout (it is expected to run on the host).

## Verified on 2026-10-23

Run in a throwaway Orca worktree of intility-id, under Windows PowerShell 5.1:

- Claude started through `orca-agent.cmd` in an Orca terminal got 8 `node_modules` volumes, `AGENT_BOX_NPM_PACKAGES` and `GH_REPO=intility/intility-id`. The host `node_modules` folders stayed empty.
- The first start installed 7 of 8 packages in about 45 s. A second start installed nothing. A lock file change on the host caused `npm ci` in that package only.
- `packages/access-tree` fails with E401 from `npm.intility.com`. The Portal uses the same registry and installs. The package has its own `.npmrc`, which is not read here. The entrypoint wrote no marker and started the agent.
- A warm `npm ci` in the Portal made 0 registry requests. With `npm.intility.com` pointed at an address that does not answer, `npm ci` completed in 15 s.
- After the automatic install, `npm run dev` answered on the host, and `vitest run` passed 141 tests.
- `-Clean` removed the volumes of the removed worktree, and kept a volume that a running container used.
- `gh pr list` in `/work` takes 0.5 to 0.6 s, the same as with `--repo`. `gh pr status` finds the branch. Without `origin`, or with a GitLab `origin`, `GH_REPO` is not set and the container starts.

## Docker Sandboxes kit (2026-10-23)

Docker Sandboxes (`sbx`) replace the launcher, the Orca proxy and the dind sidecar. Orca reaches the sandbox over SSH as the "Run on" target "Docker Agents". See `docs/handoff.md` for the spike. The kit in `sbx-kit/` gives the built-in `claude` and `opencode` agents what the launcher used to stage.

Kit schema v2 was chosen, not v3. v3 mixins do not combine with the built-in agent names, and the spike sandbox uses the built-in `claude` agent. v2 also has `files/home/` and an install step. `sbx kit add` does not accept a kit with `files/`, so a kit change needs `sbx rm` and `sbx create claude --kit .\sbx-kit`. Verified 2026-10-23 with a full `worker-start` round trip.

What `build.ps1` stages into `files/home/` (not committed, about 100 MB):

- `~/.claude/skills` (without `synced`), `commands`, `plugins/cache`, `plugins/marketplaces` (without `temp_*`) and the two plugin registries with paths rewritten to `/home/agent`. The shared `sbx skills` store is not used. `sbx skills import` would also import `synced` and the opencode copies of the plugin skills, which the plugins already provide.
- `~/.claude/CLAUDE.md` with `assets/sandbox-instructions.md` appended.
- `~/.config/opencode/opencode.json` with each `apiKey` replaced by `{env:OPENCODE_API_KEY_<PROVIDER>}`. `spec.yaml` declares one proxy-managed credential per provider that has a key. The agent sees a placeholder and the proxy injects the key for that domain. Set the keys with `sbx secret set <provider> -t <key>`.
- `.local/share/agent-box/`: the install scripts, the sanitized Claude settings, the first-run flags for `~/.claude.json`, `opencode-managed.json` from the repo root and the git identity.

The install step (`assets/install.sh`, runs as root at create or `kit add`) installs `libicu`, the .NET SDK 10 with `dotnet-install.sh`, `oc` 4.15 and `opencode`, writes `/etc/opencode/opencode.json`, and appends the environment to `/etc/sandbox-persistent.sh`, which every shell and SSH session sources. Then `agent-config.sh` runs as the agent user and merges the staged config into `~/.claude/settings.json` and `~/.claude.json` with `jq`. A merge keeps the keys that the agent kit and Orca write there (permission mode, hooks, status line).

Facts learned:

- The sandbox has `remote-settings.json` from the organization. It holds the `Bash(gh auth *)` ask rule. The kit cannot remove it. The sandbox note tells the agent not to run `gh auth`. `gh` is authenticated through the proxy.
- Orca writes its hooks and status line into the sandbox `settings.json` at the first SSH session.
- The sandbox already has Docker (the agent is in the `docker` group), `gh`, `node` 22, `uv` and `jq`. The image is Ubuntu 26.04.
- A kit network policy is added to the global policy per sandbox. The global `balanced` policy already allows GitHub, npmjs, nuget.org, dot.net and Ubuntu. The kit adds the install hosts, `api.nuget.org`, `npm.intility.com` and `*.ai.intility.app`.
- The Intility ID MCP server is registered with `sbx mcp add intility-id --url ...` and authorized over OAuth on the host. Load it into a sandbox with `sbx mcp load intility-id --sandbox <name>`. Claude in the sandbox reaches it through the MCP gateway entry that the agent kit puts in `~/.claude.json`.

## Orca per-workspace environments (considered, not used)

Orca can create a runtime per workspace from a recipe, also with local Docker. Checked 2026-10-20 with `orca skills get orca-per-workspace-env`. Not used, because:

- The worktree is cloned inside the container. Windows editors and host dev work lose direct access to the files.
- The recipe must be committed to `orca.yaml` on the primary checkout of the repo. That is team-visible.
- Agent logins are baked into an image with `docker commit`. Skills, plugins and MCP config are not covered.
- Docker Desktop on Windows and Docker access inside the environment are not documented.

The gain would be native Orca integration over SSH. Check again if the feature documents Docker Desktop and native agent launch (`worker-start --agent --model`) inside the environment.

## Next steps

1. Add opencode to `agentCmdOverrides`. Then the orca-workers skill can start GLM workers with `--agent opencode`.
2. Optional: replace `docker` with `wslc` in the launcher. Nothing else changes.

## Note on WSL containers

WSL containers (`wslc`) is a Docker-compatible runtime that runs OCI containers directly in WSL. It removes Docker Desktop as a dependency and integrates with Defender for Endpoint and Intune. It does not change this design. The image, the mounts, and the environment are the same. Start on Docker Desktop and switch when the Intune policy allows `wslc` on the machine.
