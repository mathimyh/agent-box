# agent-box

agent-box runs Orca workers (Claude Code and opencode) in a Docker Sandbox, not on the Windows host. The workers get your skills, plugins, MCP servers and GitHub access. The sandbox keeps them away from host files and host secrets.

Orca connects to the sandbox over SSH as the "Run on" target "Docker Agents". Repositories and worktrees live inside the sandbox.

See `docs/design.md` for the design and the rules learned.

## Requirements

- Windows with Docker Sandboxes: `winget install Docker.sbx`
- Orca 1.4.237 or later

## Set up a sandbox

Run the commands in PowerShell from the agent-box folder.

1. Set the global network policy (one time):

   ```powershell
   sbx policy init balanced
   ```

2. Stage your host config into the kit. Run this again after you change skills, plugins or settings on the host. The build also generates `sbx-kit.local\`, a kit with one credential per opencode model provider in your host config. It is not committed.

   ```powershell
   .\sbx-kit\build.ps1
   ```

3. Store the secrets (one time). The proxy injects them. The agent sees only a placeholder.

   ```powershell
   sbx secret set <provider>
   sbx secret set npm-intility
   ```

   One `sbx secret set` per opencode provider in your host `~/.config/opencode/opencode.json` that has an API key. The service names are listed in `sbx-kit.local\spec.yaml`. Each command asks for the value. For `npm-intility`, run `npm login --registry https://npm.intility.com --auth-type=legacy` on the host first, with your `aaXXX` account. Then use the `_authToken` value from your `~/.npmrc`.

4. Create the sandbox. Use one sandbox per repo.

   ```powershell
   sbx create claude --name <name> --kit .\sbx-kit --kit .\sbx-kit.local
   ```

   Then set a fine-grained GitHub token for the repos of this sandbox. The command asks for the value. See "GitHub token per sandbox" in `docs/design.md` for the token settings. There is no global `github` secret. The sandbox has no GitHub access until you set this token, so a missing token fails closed instead of using the host token.

   ```powershell
   sbx secret set github --sandbox <name>
   ```

5. Clone the repo in the sandbox to `/home/agent/repos/<repo>`.

6. In Orca, add an SSH target "Docker Agents" with host `<name>.sbx` and user `_default_user_`. Then register the clone as a project on that host. See "Orca" in `docs/design.md`.

## Change the kit

Config changes (skills, plugins, settings, agent rules) reach a running sandbox without a recreate. The clones, worktrees and the Orca project setup stay. Running agents keep their loaded config; the next agent session gets the new files.

```powershell
.\sbx-kit\sync.ps1 -Name <name>
```

The copy merges directories: a file removed from the kit stays in the sandbox. Changes to `spec.yaml`, `install.sh` or the network policy still need a full recreate. `sbx kit add` does not accept this kit either. To apply those, remove the sandbox and create it again (step 2 to 6). Everything in the sandbox is lost, also clones and worktrees.

## Project kits

A project kit in `kits/<project>/` adds the access that only one project needs, for example read access to its cluster with `oc`, or its MCP servers. Add it with another `--kit` at create:

```powershell
sbx create claude --name intility-id --kit .\sbx-kit --kit .\sbx-kit.local --kit .\kits\intility-id --static-mcp intility-id
```

`sbx kit add` does not accept a kit that declares credentials or static files. To add a project kit to a sandbox that exists, remove the sandbox and create it again. Then set the token that the kit declares. The comments in its `spec.yaml` tell how.

## Start workers

Use the `orca-workers` skill from an agent that runs inside the sandbox. It creates the worktrees, starts the workers and collects their results.
