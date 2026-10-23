# 008: Fast, automatic `node_modules` per worktree

Priority: high. Status: done 2026-10-23. The proposed design is implemented. See `docs/design.md`, "Builds and dev servers", and "Result" at the end of this file.

## Problem

Each worktree needs its own `npm ci` in the container. This is a manual step, and sometimes it is very slow:

- On 2026-10-22, an agent's `npm ci` in `services/intility-id-portal` stopped at the 10-minute limit of the agent's Bash tool. The npm debug log in the home volume shows 828 packages from the cache, so the tarballs were already local. npm then waited for npm.intility.com to return package metadata ("cache revalidated"). Each request took 5 to 18 seconds, and the log stops before any package was extracted. npm checks metadata against the registry by default, also when the cache is warm. The default `fetch-timeout` is 5 minutes with 2 retries, so one request that hangs can block the install for a long time.
- Agents that Orca starts (through `orca-agent.ps1`) get no `node_modules` volume, because the wrapper does not pass `-Volume`. If such an agent runs `npm ci`, it writes Linux packages into the Windows worktree, through the slow bind mount. The host install in that worktree is then broken.
- The launcher never removes `node_modules` volumes. One Portal install is 1.3 GB.

Measured on 2026-10-23 in a throwaway worktree of intility-id, Portal (832 packages), fresh volume, npm cache in the home volume (500 MB):

| Command | Time | Metadata requests |
|---|---|---|
| `npm ci` | 43 s | 8 (11 s in total, median 1.5 s) |
| `npm ci --prefer-offline --no-audit --no-fund` | 66 s | 0 |

The registry was healthy during the test, so the flags did not make the install faster. The difference between the two times is noise from load on the host (load average 15 on 16 CPUs). The value of `--prefer-offline` is that a slow or hung registry cannot block an install that the cache can supply.

### Is pnpm worth it?

No, not for this problem.

- pnpm does not remove the install per worktree. Each worktree still needs its own `node_modules` with Linux binaries in the container, and its own Windows install on the host.
- pnpm is fast because it hard-links files from one store. Linux refuses hard links across mounts. A shared store in `agent-box-home` and `node_modules` in a volume per worktree are different mounts, so pnpm copies every file. That is the same work as `npm ci` with a warm cache. A store in each worktree volume can hard-link, but then nothing is shared.
- pnpm with a lockfile does not ask the registry for metadata. npm does the same with `--prefer-offline`.
- A switch changes the repo for the whole team: lockfile, CI, and Dockerfiles.
- pnpm is not in the image. Node 22 has corepack, so pnpm can be added if a repo already uses it.

pnpm helps on the host, where the store and the worktrees are on the same drive and hard links work. That is a team decision, not an agent-box change. Not measured: pnpm in the container.

## Proposed design

1. **npm defaults in the image.** Set these in the Dockerfile as environment variables, so no `.npmrc` file changes:
   - `NPM_CONFIG_PREFER_OFFLINE=true`: use cached metadata without a check.
   - `NPM_CONFIG_AUDIT=false` and `NPM_CONFIG_FUND=false`: no audit call to the registry after the install.
   - `NPM_CONFIG_FETCH_TIMEOUT=60000`: a request that hangs fails after 1 minute, not 5.
2. **Find the packages automatically.** The launcher finds each `package-lock.json` in the worktree (not in `node_modules`, at most 3 levels deep) and adds a volume for the `node_modules` folder next to it. `-Volume` stays for other folders. With this, agents that Orca starts also get the volumes, and `orca-agent.ps1` needs no change.
3. **Install before the agent starts.** For each such volume, the entrypoint compares the SHA-256 of `package-lock.json` with a marker file `.agent-box-lock-sha256` in the volume. If the marker is missing or different, the entrypoint runs `npm ci` in that package and then writes the marker. If `npm ci` fails, the entrypoint prints the error, writes no marker, and still starts the agent. The agent starts after the install, so the agent and the entrypoint never run npm at the same time. The cost is about 1 minute on the first start of a worktree, and no time after that.
4. **Remove volumes with the worktree.** Volume names start with the container name. Add `-Clean`, which removes the volumes of worktrees that no longer exist. Run it by hand. Do not run it automatically, because a volume of a running container cannot be removed.
5. **Tell agents.** In `container-instructions.md`: `node_modules` is installed at start. Run `npm ci` only after you change `package.json`. Run long installs in the background, because the Bash tool stops after 10 minutes.

## Decisions

Made 2026-10-23: install at start, before the agent starts. Find the packages automatically.

## Verify

1. Start an agent from the Orca UI in a new intility-id worktree. `docker volume ls` shows a `node_modules` volume for each package with a `package-lock.json`. The host worktree has no Linux packages in `node_modules`.
2. On the first start, the entrypoint runs `npm ci` for each package and writes the marker. The second start runs no install.
3. Change `package-lock.json` (for example with `npm install <package>` on the host). The next start runs `npm ci` again.
4. `npm config get prefer-offline` in the container prints `true`. An `npm ci` with a warm cache makes no "cache revalidated" requests in the debug log.
5. Point the registry at an address that does not answer (in a throwaway container). With a warm cache, `npm ci` still completes.
6. `npm run dev` and `npm test` work in the Portal after the automatic install.
7. After `orca worktree rm`, `-Clean` removes the volumes of that worktree and keeps the volumes of running containers.

## Result

Verified on 2026-10-23 in a throwaway intility-id worktree, under Windows PowerShell 5.1.

1. Pass, with one change to the test. Claude was started with `orca-agent.cmd claude` in an Orca terminal (`orca terminal create`). This is the command that the Orca UI runs through `agentCmdOverrides`. The UI button was not clicked. 8 volumes were created, one for each `package-lock.json`. The host `node_modules` folders stayed empty.
2. Pass. The first start installed 7 packages and wrote 7 markers, in about 45 s in total (the Portal took 22 s). The second start installed nothing and took 9.5 s.
3. Pass. `npm install --package-lock-only is-number` on the host in `packages/id-errors`. The next start ran `npm ci` in that package only, and the marker has the new SHA-256.
4. Pass. `npm config get prefer-offline` prints `true`. A warm `npm ci` in the Portal made 0 "cache revalidated" requests and 0 fetches.
5. Pass. `npm.intility.com` and `registry.npmjs.org` pointed at `10.255.255.1` in a throwaway container. `npm ci` for the Portal completed in 15 s, with and without install scripts.
6. Pass. `npm run dev -- --host 0.0.0.0 --port 3913` with `-Port 3913` answered 200 in the container and on the host. `vitest run` passed 25 files and 141 tests.
7. Pass. After `orca worktree rm`, `-Clean` removed the 8 volumes of the worktree. A labeled volume for a missing path that a running container used was kept, and removed after the container stopped. Windows does not let you remove the folder of a running container, so this case used a volume made for the test.

Found during the test:

- `packages/access-tree` fails at each start with E401 from `npm.intility.com`. Its tarballs are not in the cache. The Portal uses the same registry and installs. `access-tree` has its own `.npmrc`, which probably changes the auth for that package. The file was not read, because it can hold credentials. The entrypoint behaves as designed: it prints the error, writes no marker and starts the agent.
- A manual `npm ci` removes the marker, so the next start installs again.
- Volumes from before this change have no `agent-box.worktree` label. `-Clean` ignores them. On 2026-10-23 this is only `agent-box-978-nuget-lockfiles-services-intility-id-portal-node_modules`.
