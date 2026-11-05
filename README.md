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

2. Stage your host config into the kit. `new-sandbox.ps1` and `sync.ps1` run this build themselves; run it alone only to check the staging. The build also generates `sbx-kit.local\`, a kit with one credential per opencode model provider in your host config. It is not committed.

   ```powershell
   .\sbx-kit\build.ps1
   ```

3. Store the secrets (one time). The proxy injects them. The agent sees only a placeholder.

   ```powershell
   sbx secret set <provider>
   sbx secret set npm-intility
   ```

   One `sbx secret set` per opencode provider in your host `~/.config/opencode/opencode.json` that has an API key. The service names are listed in `sbx-kit.local\spec.yaml`. Each command asks for the value. For `npm-intility`, run `npm login --registry https://npm.intility.com --auth-type=legacy` on the host first, with your `aaXXX` account. Then use the `_authToken` value from your `~/.npmrc`.

4. Create the sandbox. Use one sandbox per repo. One command builds the kit, checks that every kit credential has a stored secret (it stops before the create when one is missing), creates the sandbox, asks for the scoped GitHub token and clones the repo to `/home/agent/repos/<repo>`:

   ```powershell
   .\sbx-kit\new-sandbox.ps1 -Name <name> -Repo <owner/repo>
   ```

   There is no global `github` secret. The sandbox has no GitHub access until the token is set, so a missing token fails closed instead of using the host token. See "GitHub token per sandbox" in `docs/design.md` for the token settings.

5. Finish the Orca setup. Add an SSH target with host `<name>.sbx` and user `_default_user_`. Orca installs its daemon on the first connection, about a minute. Then take the environment id from `orca host list` and register the clone as a project. The script prints these commands with the values filled in. See "Orca" in `docs/design.md`.

   ```powershell
   orca project setup-existing-folder --project github:<owner/repo> --host runtime:<environment-id> --path /home/agent/repos/<repo> --kind git
   ```

## Change the kit

Config changes (skills, plugins, settings, agent rules) reach a running sandbox without a recreate. The clones, worktrees and the Orca project setup stay. Running agents keep their loaded config; the next agent session gets the new files.

```powershell
.\sbx-kit\sync.ps1 -Name <name>
```

The copy merges directories: a file removed from the kit stays in the sandbox. Changes to `spec.yaml`, `install.sh` or the network policy still need a full recreate. `sbx kit add` does not accept this kit either. To apply those, remove the sandbox and run step 4 again. Everything in the sandbox is lost, also clones and worktrees.

## Project kits

A project kit in `kits/<project>/` adds the access that only one project needs, for example read access to its cluster with `oc`, or its MCP servers. Add it with `-Kit`, and `-StaticMcp` for its MCP servers. The command asks for the token the kit declares:

```powershell
.\sbx-kit\new-sandbox.ps1 -Name intility-id -Repo intility/intility-id -Kit intility-id -StaticMcp intility-id
```

`sbx kit add` does not accept a kit that declares credentials or static files. To add a project kit to a sandbox that exists, remove the sandbox and create it again with the same command.

## Start workers

Use the `orca-workers` skill from an agent that runs inside the sandbox. It creates the worktrees, starts the workers and collects their results.
