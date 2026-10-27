# agent-box: Orca workers in a Docker Sandbox

Status: in use since 2026-10-23. A full fanout with the `orca-workers` skill is verified.

## Goal

Run coding agents (Claude Code, opencode) in a sandbox, not on the Windows host. Give the agents the user's skills, plugins, MCP servers and GitHub access. Use them from Orca with no change to how Orca manages worktrees.

## Design

Docker Sandboxes (`sbx`) give a micro VM with its own file system, a network policy and a proxy that injects credentials. Orca reaches the sandbox over SSH as the "Run on" target "Docker Agents". Repositories and worktrees live inside the sandbox. The Windows host has no copy of them.

The kit in `sbx-kit/` adds the user's config and tools to the built-in `claude` agent of `sbx`.

| Decision | Choice | Reason |
|---|---|---|
| Isolation | Docker Sandboxes | The sandbox has no host mount. The agent cannot change host config or read host secrets. |
| Worktree location | Inside the sandbox | git on a Linux file system is fast (`git status` in 0.03 s). A bind mount from Windows took 13 to 19 s. |
| Orca integration | SSH "Run on" target | Orca runs its daemon and status hooks in the sandbox. Agents start from the Orca UI or with `worker-start`. |
| Secrets | `sbx secret` | The proxy injects the real token for the target domain. The agent sees only a placeholder. |
| Grain | One sandbox per project, with a scoped GitHub token | A worker can only reach the repos of its project. Set the token with `sbx secret set github --sandbox <name>`. See "GitHub token per sandbox". |

Known trade-off: all worktrees and the main checkout share one file system and one user. Only the brief stops a worker from changing main or a sibling worktree.

## Files

| File | Purpose |
|---|---|
| `sbx-kit/spec.yaml` | Kit spec (schema v2): network allow list, the npm credential, agent instructions, install step. |
| `sbx-kit/allowlist.txt` | Skills, commands and plugins to stage into the sandbox. Everything else stays on the host. |
| `sbx-kit/build.ps1` | Stages the host config into `sbx-kit/files/` (not committed) and generates `sbx-kit.local/`. |
| `sbx-kit.local/spec.yaml` | Generated local kit (not committed): one credential and network allow entry per opencode model provider in the host config. |
| `sbx-kit/assets/install.sh` | Install step. Runs as root at `sbx create`. |
| `sbx-kit/assets/agent-config.sh` | Merges the staged Claude config into the agent user's home. |
| `sbx-kit/assets/claude-json.json` | First-run flags for `~/.claude.json`. |
| `opencode-managed.json` | Approved opencode permissions. See "Agent permissions". |
| `kits/<project>/` | Project kit: `spec.yaml` plus `files/` (for example the opencode MCP patch). See "Project kits". |

## Docker Sandboxes kit

Kit schema v2 was chosen, not v3. v3 mixins do not combine with the built-in agent names. v2 also has `files/home/` and an install step. `sbx kit add` does not accept a kit with `files/`. A kit change therefore needs a new sandbox:

```powershell
sbx rm <name>; sbx create claude --name <name> --kit .\sbx-kit --kit .\sbx-kit.local
```

Everything in the sandbox is lost: clones, worktrees and the Orca project setup. Clone the repo again after the create.

What `build.ps1` stages into `files/home/` (about 15 MB):

- The allow-listed skills, commands and plugins, per `allowlist.txt`. For plugins: only the cache versions the registry entries point at, only the marketplaces those plugins need, and both plugin registries filtered to match, with paths changed to `/home/agent`. A listed name missing on the host fails the build. An allow list was chosen over a deny list to keep the worker context small: every staged skill costs its description in every worker session. The staged size drops from about 100 MB to about 15 MB, mostly because the `anthropic-agent-skills` marketplace (no installed plugins) and the `mattpocock-skills` cache (41 MB, mostly bundled `node_modules`) stay out. The `enabledPlugins` flags in the staged settings keep only allowed plugins, and the build fails when none match, so a key-format change cannot silently disable all plugins. The shared `sbx skills` store is not used. `sbx skills import` would also import `synced` and the opencode copies of the plugin skills, which the plugins already give.
- The shared agent rules. `~/.config/opencode/AGENTS.md` is the source of truth for both host agents, because opencode reads it natively as global rules and Claude Code has no user-level AGENTS.md: the host `~/.claude/CLAUDE.md` is a one-line `@` import of it. `build.ps1` strips the marked host-only blocks (Windows, PowerShell, the host skill store, host Orca dispatch) and stages the rest as both `~/.claude/CLAUDE.md` and `~/.config/opencode/AGENTS.md`. The sandbox note is `agentInstructions.content` in `spec.yaml`; the engine writes it to the kit memory and links it from the generated AI file, so every agent in the sandbox loads it.
- `~/.config/opencode/opencode.json` with each `apiKey` replaced by `{env:OPENCODE_API_KEY_<PROVIDER>}`. The personal model credentials go into the generated local kit `sbx-kit.local/` (not committed), one per provider with its endpoint domain: the base kit stays free of personal endpoints, so a teammate can use it unchanged. `build.ps1` stops when a provider has no credential with the matching env name and domain. Set the keys with `sbx secret set <provider> -t <key>`. The `mcp` section is dropped: its entries point at the host's direct server URLs, their headers and environment can hold secrets in plain text, and the sandbox has no OAuth tokens for them. opencode gets an MCP server only through a project kit. See "Project kits".
- No npm token. `spec.yaml` declares the credential `npm-intility`, and the proxy adds `Authorization: Bearer <token>` to each request to `npm.intility.com`. npm in the sandbox has no auth config. `npm login` in the sandbox is not necessary, and it would put the token in a file that every worker can read.
- `.local/share/agent-box/`: the install scripts, the sanitized Claude settings, the first-run flags, `opencode-managed.json` and the git identity.

The install step installs `libicu`, the .NET SDK 10, `oc` 4.15, npm 11 and `opencode`, writes `/etc/opencode/opencode.json`, and adds the environment to `/etc/sandbox-persistent.sh`. Every shell and SSH session reads that file. Then `agent-config.sh` runs as the agent user and merges the staged config into `~/.claude/settings.json` and `~/.claude.json` with `jq`. The merge keeps the keys that the agent kit and Orca write there (permission mode, hooks, status line).

Facts learned:

- The sandbox has `remote-settings.json` from the organization. It holds the `Bash(gh auth *)` ask rule, and the kit cannot remove it. The sandbox note tells the agent not to run `gh auth`. `gh` is authenticated through the proxy.
- Orca writes its hooks and status line into the sandbox `settings.json` at the first SSH session.
- The sandbox already has Docker (the agent is in the `docker` group), `gh`, `node` 22, `uv` and `jq`. The image is Ubuntu 26.04.
- The image has Ubuntu's npm 9.2.0. With Node 22, `npm ci` in the Portal fails after about 5 s with `ECONNRESET` ("aborted"). The registry and the proxy are not the cause: curl downloads all 861 archives, also slowly. npm 11 installs the Portal in 17 s. The install step therefore installs npm 11.
- The kit network policy is added to the global policy per sandbox. The global `balanced` policy allows GitHub, npmjs, nuget.org, dot.net and Ubuntu. The kit adds the install hosts, `api.nuget.org`, `npm.intility.com`, `*.ai.intility.app` and the opencode model catalog. The local kit adds the exact endpoint domain of each opencode model provider.
- The Intility ID MCP server is registered with `sbx mcp add intility-id --url ...` and authorized over OAuth on the host. Load it into a sandbox with `sbx mcp load intility-id --sandbox <name>`, or with `--static-mcp` at create.
- Auto mode refuses `sbx rm`, `sbx create` and `sbx kit add`. The user runs them from the agent-box folder.

## GitHub token per sandbox

Each sandbox gets a fine-grained token for the repos of its project. There is no global `github` secret. A sandbox without a per-sandbox token has no GitHub access, so a missing token fails closed instead of falling back to the full host token. Tested 2026-10-26 on `intility-id`: the selected repo had read and push access, and a private repo that was not selected returned 404.

Token settings:

- Resource owner: the org that owns the repos. If the org requires approval, an org admin must approve the token.
- Repository access: "Only select repositories". Select the project repo and the repos that the workers read from. Every selected repo gets the same permissions, so select only what the workers need. Public repos are readable without selection.
- Permissions: Contents, Pull requests and Issues read and write. Actions and Commit statuses read. Metadata read (required). Workflows no access, so agents cannot change `.github/workflows`.

Two tokens (read on all repos, write on one) do not work. The proxy selects the token by domain, not by repo. Contents write also allows a push to `main`, so the selected repos need branch protection that requires a PR.

## Agent permissions

Orca starts Claude in the sandbox with `--dangerously-skip-permissions`, so Claude does not ask for permissions (verified 2026-10-27). The staged settings set `skipDangerousModePermissionPrompt` and `bypassPermissionsModeAccepted`. These flags suppress the acceptance prompt for bypass mode, so an unattended worker does not stop at startup. The sandbox and its network policy are the security boundary.

opencode has no bypass flag. Its approved permissions are in `opencode-managed.json`.

- The install step copies the file to `/etc/opencode/opencode.json`. This is opencode's managed config on Linux. It has a higher priority than the user config and the project config.
- The sandbox sets `OPENCODE_DISABLE_PROJECT_CONFIG=1`. The last matching permission rule wins, and a merged key keeps the position of the layer that added it first. Without the flag, an `opencode.json` in the repo could put a key such as `*.env` before `*` and so cancel the deny. The flag is in the opencode binary but not documented. Verified with opencode 1.19.3 and `opencode debug config`.
- The read denies stop accidental reads. They are not a security boundary, because `bash` is `allow`. The boundary is the sandbox.
- `"*": "allow"` also allows all MCP tools. The base kit stages no MCP server, so opencode starts with none. An opencode permission pattern matches tool names only, so ask-by-default for a server can only come from rules that name it. A project kit therefore adds the MCP entry and its rules together. In `kits/intility-id`, the Intility ID tools (`intility-id_*`) are `ask`, and only the read tools (`get`, `list`, `check`, `batch_check`, `describe`, `preview_delete`) are allowed. A new write tool on the server therefore asks before it runs. The write tools act with the user's identity in dev.

## Orca

- Orca 1.4.237 or later. On 1.4.218 the `orca` CLI in the sandbox could create a terminal on Windows. On 1.4.237 it sees only the sandbox as `local`, and `path:C:/...` selectors do not resolve. Keep Orca updated.
- SSH target "Docker Agents" = `<name>.sbx`, user `_default_user_`. From Git Bash, `ssh <name>.sbx` fails. Use `C:\Windows\System32\OpenSSH\ssh.exe`.
- In a plain SSH session the `orca` CLI is not on PATH. Use `~/.orca/cli/bin/orca`.
- After a new sandbox, Orca installs its daemon again at the next connection. The UI shows "connecting" for about a minute. Then register the clone and create worktrees through the paired runtime. `orca host list` prints the environment id. In Git Bash, set `MSYS_NO_PATHCONV=1` first.

```
orca project setup-existing-folder --project github:intility/intility-id --host runtime:<environment-id> --path /home/agent/repos/intility-id --kind git
orca worktree create --project intility-id --host runtime:<environment-id> --name <name>
```

  Worktrees go to `/home/agent/orca/workspaces/<repo>/<name>`.

### Coordinator inside the sandbox

This is the normal path. The `orca-workers` skill describes it. Inside the sandbox the Orca host is `local` and worktrees are plain `path:` selectors, so no `--on`, `--environment`, `--host runtime:` or `--from` is necessary.

### Coordinator on the Windows host

- `worker-start` needs `--on "Docker Agents" --worktree path:/home/agent/orca/workspaces/<repo>/<name> --agent claude`. Without `--on` the terminal is not created and the task fails silently.
- Terminal handles are different on each host. Use `--environment "Docker Agents"` for `terminal read` and `terminal send` on sandbox terminals.
- From outside an Orca terminal: create a shell terminal on the host (`orca terminal create --worktree path:<main checkout>`), then `run-create --objective ... --from <handle>`, then `worker-start ... --from <handle>`. Read results with `orchestration check --terminal <handle>`. `worker-show` and `worker-read` take `--dispatch` and `--environment`, not `--from`.
- `worker-start` returns `stage: input_accepted` on success.

## Project kits

Access that only one project needs goes in a project kit, not in `sbx-kit`. `sbx create` takes `--kit` more than one time. Kit order is load-bearing: pass `.\sbx-kit` first. A project kit that merges into files the base kit writes fails the create loudly when the base kit is missing.

`kits/intility-id` gives `oc` read access to the intility-id dev cluster, and gives opencode the Intility ID MCP tools:

- The network policy allows only the cluster API host.
- The ServiceAccount `sandbox-agents/intility-id-sandbox` has the ClusterRole `view`. It can read all namespaces, but not Secrets. ArgoCD manages it from the intility-id repo (intility/intility-id#1151).
- The `view` role also reads pod logs and ConfigMaps. Pod logs can hold secrets. Workers should read only what the task needs.
- The proxy adds the ServiceAccount token to requests to the API host. The kubeconfig in the sandbox has no credentials, so the agent never sees the token. A token from `oc login` in the sandbox would go in `~/.kube/config`, where every agent can read it.
- The token comes from `oc create token` and expires after 90 days. Nothing rotates it and nothing sends a reminder. Set a reminder, or create and set a new token before it expires.
- A v2 kit cannot declare MCP servers, so `--static-mcp intility-id` stays on the create command. That serves Claude. opencode gets the server from this kit: its install step merges `files/home/agent/.local/share/agent-box/intility-id/opencode-patch.json` into both opencode configs with `jq`. The permission rules go into `/etc/opencode/opencode.json`, the gateway entry into `~/.config/opencode/opencode.json`.
- The gateway entry points at `http://mcp-gateway.docker.internal/mcp`, the same server that Claude uses. The sandbox has no OAuth token for the direct URL, and the proxy adds the token for the gateway. The rules ask first and allow only the read tools, so a new write tool on the server asks before it runs.
- Stacked kits apply each stage in `--kit` order: the kit's static `files/` land before any install command runs, and its install commands run after the base kit's. The merges therefore see both files in their final place.

## Orca per-workspace environments (considered, not used)

Orca can create a runtime per workspace from a recipe, also with local Docker. Checked 2026-10-20 with `orca skills get orca-per-workspace-env`. Not used, because:

- The recipe must be committed to `orca.yaml` on the primary checkout of the repo. That is visible to the team.
- Agent logins are put into an image with `docker commit`. Skills, plugins and MCP config are not covered.
- Docker Desktop on Windows and Docker access inside the environment are not documented.

Docker Sandboxes give the same native Orca integration over SSH without these problems.
