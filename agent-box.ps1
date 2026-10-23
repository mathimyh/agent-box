<#
.SYNOPSIS
Start a sandboxed agent (Claude Code or opencode) in a container bound to one git worktree.

.DESCRIPTION
Stages sanitized host config, then runs the agent-box image with the worktree
mounted at /work. See docs/design.md.

Works in Windows PowerShell 5.1 and pwsh 7.

.EXAMPLE
agent-box.ps1 -Agent claude
agent-box.ps1 -Agent opencode -Worktree C:\Users\me\orca\workspaces\repo\task
agent-box.ps1 -Shell                # joins the running agent container, if any
agent-box.ps1 -Shell -OAuthRelay   # then: opencode mcp auth <server>
agent-box.ps1 -Build
agent-box.ps1 -Clean                # removes volumes of removed worktrees
#>
[CmdletBinding()]
param(
    [ValidateSet('claude', 'opencode')]
    [string]$Agent = 'claude',
    [string]$Worktree = (Get-Location).Path,
    [string]$Prompt,
    [string]$Model,
    [string[]]$AgentArgs,
    [switch]$Build,
    [switch]$Shell,
    [string]$Command,
    [switch]$OAuthRelay,
    [switch]$Docker,
    [int[]]$Port,
    [string[]]$Volume,
    [switch]$NoNpmInstall,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'

$image = 'agent-box:local'
$dindImage = 'agent-box-dind:local'
$proxyImage = 'agent-box-orca-proxy:local'
$proxyName = 'agent-box-orca-proxy'
$root = $PSScriptRoot
$claudeDir = Join-Path $HOME '.claude'
$opencodeDir = Join-Path $HOME '.config\opencode'

function Convert-JsonFile {
    param([string]$Path)
    Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-JsonFile {
    param($Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Rewrite Windows config paths to the container home.
function Convert-HostPath {
    param([string]$Text)
    $backslash = $claudeDir.Replace('\', '\\')
    $forward = $claudeDir.Replace('\', '/')
    $Text = $Text.Replace($backslash, '/home/agent/.claude').Replace($forward, '/home/agent/.claude')
    # The rest of each rewritten path still has JSON-escaped backslashes.
    return [regex]::Replace($Text, '/home/agent/\.claude(?:\\\\[^"\\]+)+', { param($m) $m.Value -replace '\\\\', '/' })
}

# --- clean ------------------------------------------------------------------
# Dependency volumes carry the worktree path in a label. Remove the volumes of
# worktrees that no longer exist. Keep a volume that a container uses.

if ($Clean) {
    $vols = @(docker volume ls -q --filter label=agent-box.worktree)
    if ($vols) {
        # No Go template: Windows PowerShell 5.1 breaks the quotes in it.
        $info = (docker volume inspect @vols) -join "`n" | ConvertFrom-Json
        foreach ($v in $info) {
            $path = $v.Labels.'agent-box.worktree'
            if (Test-Path -LiteralPath $path) { continue }
            if (docker ps -aq --filter "volume=$($v.Name)") {
                Write-Host "Kept $($v.Name). A container uses it."
                continue
            }
            docker volume rm $v.Name | Out-Null
            Write-Host "Removed $($v.Name)"
        }
    }
    return
}

# --- image ------------------------------------------------------------------

$haveImage = docker image inspect $image 2>$null
if ($Build -or -not $haveImage) {
    docker build -t $image $root
    if ($LASTEXITCODE -ne 0) { throw 'docker build failed' }
}
$haveDindImage = docker image inspect $dindImage 2>$null
if ($Build -or ($Docker -and -not $haveDindImage)) {
    docker build -t $dindImage (Join-Path $root 'dind')
    if ($LASTEXITCODE -ne 0) { throw 'docker build of the dind sidecar failed' }
}
$haveProxyImage = docker image inspect $proxyImage 2>$null
if ($Build -or -not $haveProxyImage) {
    docker build -t $proxyImage (Join-Path $root 'orca-proxy')
    if ($LASTEXITCODE -ne 0) { throw 'docker build of the Orca proxy failed' }
    # Recreate the proxy from the new image on the next start.
    if (docker ps -aq --filter "name=^/$proxyName$") { docker rm -f $proxyName | Out-Null }
}
if ($Build -and -not $Shell -and -not $PSBoundParameters.ContainsKey('Agent')) { return }

# --- worktree and git -------------------------------------------------------

$Worktree = (Resolve-Path $Worktree).Path.TrimEnd('\')
$name = 'agent-box-' + (Split-Path $Worktree -Leaf).ToLower() -replace '[^a-z0-9_.-]', '-'

# -Shell joins the agent container of this worktree when it runs, so a host
# terminal can work in the same environment as the agent.
if ($Shell -and -not $Command -and (docker ps -q --filter "name=^/$name$")) {
    docker exec -it -w /work $name bash
    exit $LASTEXITCODE
}

$mounts = @('-v', "${Worktree}:/work")
$envs = @()

$gitFile = Join-Path $Worktree '.git'
if (Test-Path $gitFile -PathType Leaf) {
    # Linked worktree. The .git file holds a Windows path to the main repo.
    $gitdir = ((Get-Content $gitFile -Raw) -replace '^gitdir:\s*', '').Trim()
    if ($gitdir -notmatch '^(.*[\\/]\.git)[\\/]worktrees[\\/]([^\\/]+)$') {
        throw "Unexpected gitdir in ${gitFile}: $gitdir"
    }
    $mainGit = $Matches[1].Replace('/', '\')
    $wtName = $Matches[2]
    $mounts += @('-v', "${mainGit}:/repo/.git")
    $envs += @('-e', "GIT_DIR=/repo/.git/worktrees/$wtName", '-e', 'GIT_WORK_TREE=/work')
}
elseif (-not (Test-Path $gitFile -PathType Container)) {
    throw "$Worktree is not a git worktree"
}

$autocrlf = git config --global core.autocrlf 2>$null
if ($autocrlf) { $envs += @('-e', "GIT_AUTOCRLF=$autocrlf") }

# With GH_REPO, gh does not run git to find the repo. Each git call is slow on
# the bind mount. See docs/issues/009.
$origin = git -C $Worktree config --get remote.origin.url 2>$null
if ($origin -match 'github\.com[:/]([^/]+/[^/]+?)(\.git)?/?$') {
    $envs += @('-e', "GH_REPO=$($Matches[1])")
}

# --- staged host config -----------------------------------------------------

$stage = Join-Path $root ".staging\$name"
$stageClaude = Join-Path $stage 'claude'
New-Item -ItemType Directory -Force -Path $stageClaude | Out-Null

# settings.json without host-only hooks and status line.
$settings = Convert-JsonFile (Join-Path $claudeDir 'settings.json')
foreach ($key in 'hooks', 'statusLine') {
    if ($settings.PSObject.Properties[$key]) { $settings.PSObject.Properties.Remove($key) }
}
Write-JsonFile $settings (Join-Path $stageClaude 'settings.json')

Copy-Item (Join-Path $claudeDir 'CLAUDE.md') (Join-Path $stageClaude 'CLAUDE.md')

# User-scope MCP servers live in ~/.claude.json next to unrelated state.
$claudeJson = Convert-JsonFile (Join-Path $HOME '.claude.json')
$mcp = @{ mcpServers = @{} }
if ($claudeJson.mcpServers) { $mcp.mcpServers = $claudeJson.mcpServers }
Write-JsonFile $mcp (Join-Path $stageClaude 'mcp.json')

# Plugin registries carry absolute Windows paths.
foreach ($f in 'installed_plugins.json', 'known_marketplaces.json') {
    $text = Get-Content (Join-Path $claudeDir "plugins\$f") -Raw -Encoding UTF8
    [System.IO.File]::WriteAllText((Join-Path $stageClaude $f), (Convert-HostPath $text), (New-Object System.Text.UTF8Encoding($false)))
}

# --- Orca CLI ---------------------------------------------------------------
# The Orca CLI is plain Node code shipped outside app.asar. Copy it and its
# four npm dependencies from the host install so the container runs the same
# version as the host app. Refreshed when the host app version changes.

$orcaResources = Join-Path $env:LOCALAPPDATA 'Programs\orca\resources'
$orcaOut = Join-Path $orcaResources 'app.asar.unpacked\out'
$orcaStage = Join-Path $root '.staging\orca-cli'
$orcaMounts = @()
if (Test-Path (Join-Path $orcaOut 'cli\index.js')) {
    $hostVersion = (Convert-JsonFile (Join-Path $orcaOut 'package.json')).version
    $stagedVersionFile = Join-Path $orcaStage 'version'
    $stagedVersion = if (Test-Path $stagedVersionFile) { Get-Content $stagedVersionFile -Raw } else { '' }
    if ($stagedVersion.Trim() -ne $hostVersion) {
        if (Test-Path $orcaStage) { Remove-Item $orcaStage -Recurse -Force }
        New-Item -ItemType Directory -Force -Path (Join-Path $orcaStage 'out'), (Join-Path $orcaStage 'node_modules') | Out-Null
        foreach ($item in 'cli', 'shared', 'package.json') {
            Copy-Item (Join-Path $orcaOut $item) (Join-Path $orcaStage "out\$item") -Recurse
        }
        foreach ($pkg in 'zod', 'ws', 'tweetnacl', 'yaml') {
            Copy-Item (Join-Path $orcaResources "node_modules\$pkg") (Join-Path $orcaStage "node_modules\$pkg") -Recurse
        }
        [System.IO.File]::WriteAllText($stagedVersionFile, $hostVersion)
    }
    $orcaMounts = @('-v', "${orcaStage}:/opt/orca-cli:ro")
    # The container reaches the host runtime only through the filtering proxy,
    # which allows orchestration calls and refuses the rest. The real Orca
    # pairing stays in the proxy volume. See docs/design.md, "Orca proxy".
    if (-not (docker ps -q --filter "name=^/$proxyName$")) {
        if (docker ps -aq --filter "name=^/$proxyName$") {
            docker start $proxyName | Out-Null
        }
        else {
            docker run -d --name $proxyName -p 127.0.0.1:6769:6769 -v "${proxyName}:/data" $proxyImage | Out-Null
        }
        Start-Sleep -Seconds 1
        if (-not (docker ps -q --filter "name=^/$proxyName$")) {
            throw "The Orca proxy did not start. Pair it once (see docs/design.md, 'Orca proxy'), then check: docker logs $proxyName"
        }
    }
    $env:AGENT_BOX_ORCA_LINK = docker exec $proxyName node proxy.js link
    $envs += @('-e', 'AGENT_BOX_ORCA_LINK', '-e', 'ORCA_CLI_COMMAND=orca', '-e', 'ORCA_ENVIRONMENT=proxy')
    # "current" does not resolve on a remote runtime. Agents select this
    # worktree with: --worktree path:$AGENT_BOX_WORKTREE_PATH
    $envs += @('-e', ('AGENT_BOX_WORKTREE_PATH=' + $Worktree.Replace('\', '/')))
    # Orca sets these in its own terminals. They give the agent its sender
    # identity for orchestration commands and its current worktree.
    foreach ($var in 'ORCA_TERMINAL_HANDLE', 'ORCA_PANE_KEY', 'ORCA_WORKTREE_ID', 'ORCA_WORKSPACE_ID') {
        if (Test-Path "Env:$var") { $envs += @('-e', $var) }
    }
}

# Handoffs and other files the user reads on the host. /tmp is lost when the
# container stops. TMPDIR stays /tmp, because .NET and other tools create Unix
# sockets there, and those do not work on a Windows bind mount.
$scratch = Join-Path $root "scratch\$name"
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
$envs += @('-e', "AGENT_BOX_SCRATCH_HOST=$scratch")

$mounts += $orcaMounts + @(
    '-v', "${scratch}:/scratch",
    '-v', 'agent-box-home:/home/agent',
    '-v', "${stage}:/host-config:ro",
    '-v', "$claudeDir\skills:/home/agent/.claude/skills:ro",
    '-v', "$claudeDir\commands:/home/agent/.claude/commands:ro",
    '-v', "$claudeDir\plugins\cache:/home/agent/.claude/plugins/cache:ro",
    '-v', "$claudeDir\plugins\marketplaces:/home/agent/.claude/plugins/marketplaces:ro",
    '-v', "${opencodeDir}:/home/agent/.config/opencode:ro"
)

# --- secrets ----------------------------------------------------------------

$env:GH_TOKEN = gh auth token
if (-not $env:GH_TOKEN) { throw 'gh auth token returned nothing. Run: gh auth login' }
$envs += @('-e', 'GH_TOKEN')

# One-time opencode MCP OAuth. Publishes the fixed callback port on the host.
$ports = @()
if ($OAuthRelay) {
    $ports = @('-p', '127.0.0.1:19876:19876')
    $envs += @('-e', 'AGENT_BOX_OAUTH_RELAY=1')
}

# Dev servers. The same port on the host loopback. The server must listen on
# 0.0.0.0 in the container, for example: npm run dev -- --host 0.0.0.0
foreach ($p in $Port) { $ports += @('-p', "127.0.0.1:${p}:${p}") }

# --- run --------------------------------------------------------------------

$cmd = @()
$tty = @('-it')
if ($Command) {
    # Non-interactive, for checks and scripted runs. Passed by env var because
    # Windows PowerShell 5.1 breaks embedded quotes in native command arguments.
    $env:AGENT_BOX_COMMAND = $Command
    $envs += @('-e', 'AGENT_BOX_COMMAND')
    $cmd = @('shell')
    $tty = @()
}
elseif ($Shell) {
    $cmd = @('shell')
}
else {
    $cmd = @($Agent)
    if ($Model) { $cmd += @('--model', $Model) }
    if ($AgentArgs) { $cmd += $AgentArgs }
    if ($Prompt) {
        if ($Agent -eq 'opencode') { $cmd += @('--prompt', $Prompt) } else { $cmd += @($Prompt) }
    }
}

# The name comes from the worktree folder. Do not replace a running container,
# because that stops the agent in it.
if (docker ps -q --filter "name=^/$name$") {
    throw "Container $name is already running for this worktree. Stop it first: docker stop $name"
}
docker rm -f $name 2>$null | Out-Null

# --- dependency volumes -----------------------------------------------------
# Each package with a package-lock.json gets its node_modules in a named volume
# per worktree, and the entrypoint installs it. -Volume adds other
# worktree-relative folders. Linux packages must not mix with Windows ones,
# and a volume is much faster than the bind mount. See docs/issues/008.

# Package folders at most 3 levels below the worktree. Skips node_modules and
# dot folders such as .git.
function Find-NpmPackage {
    param([string]$Dir, [int]$Depth)
    if (Test-Path -LiteralPath (Join-Path $Dir 'package-lock.json')) { $Dir }
    if ($Depth -ge 3) { return }
    foreach ($sub in Get-ChildItem -LiteralPath $Dir -Directory -Force) {
        if ($sub.Name -ne 'node_modules' -and -not $sub.Name.StartsWith('.')) {
            Find-NpmPackage $sub.FullName ($Depth + 1)
        }
    }
}

# Worktree-relative, with forward slashes. "." is the worktree itself.
$npmPackages = @(Find-NpmPackage $Worktree 0 | ForEach-Object {
    $rel = $_.Substring($Worktree.Length).Replace('\', '/').Trim('/')
    if ($rel) { $rel } else { '.' }
})
$volumeDirs = @($npmPackages | ForEach-Object { if ($_ -eq '.') { 'node_modules' } else { "$_/node_modules" } })
foreach ($rel in $Volume) {
    $rel = $rel.Replace('\', '/').Trim('/')
    if ($volumeDirs -notcontains $rel) { $volumeDirs += $rel }
}
# -NoNpmInstall keeps the volumes, so a manual npm ci still writes into a
# volume and not into the Windows worktree.
if ($npmPackages -and -not $NoNpmInstall) { $envs +=@('-e', ('AGENT_BOX_NPM_PACKAGES=' + ($npmPackages -join ':'))) }

$existingVolumes = @(docker volume ls -q)
$newVolumes = @()
foreach ($rel in $volumeDirs) {
    $vol = "$name-" + ($rel.ToLower() -replace '[^a-z0-9_.-]', '-')
    if ($existingVolumes -notcontains $vol) {
        # The label tells -Clean which worktree owns the volume.
        docker volume create --label "agent-box.worktree=$Worktree" $vol | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not create volume $vol" }
        $newVolumes += $vol
    }
    $mounts += @('-v', "${vol}:/work/$rel")
}

# A new volume is owned by root. Hand the new ones to the agent user once.
if ($newVolumes) {
    $chownMounts = @()
    $chownPaths = @()
    for ($i = 0; $i -lt $newVolumes.Count; $i++) {
        $chownMounts += @('-v', "$($newVolumes[$i]):/v/$i")
        $chownPaths += "/v/$i"
    }
    docker run --rm --user root --entrypoint chown @chownMounts $image agent:agent @chownPaths
    if ($LASTEXITCODE -ne 0) { throw "Could not prepare the volumes $($newVolumes -join ', ')" }
}

# --- dind sidecar -----------------------------------------------------------
# A private Docker engine for Testcontainers. It runs privileged, so the
# authorization plugin in dind/authz.py refuses containers that ask for host
# access. The agent reaches it only over a private network. See docs/design.md.

$sidecar = "$name-dind"
$network = @()

# docker writes to stderr for a missing network, which stops Windows
# PowerShell 5.1 under ErrorActionPreference Stop. Check first.
function Remove-Sidecar {
    docker rm -f $sidecar 2>$null | Out-Null
    if (docker network ls -q --filter "name=^$name$") { docker network rm $name | Out-Null }
}
if ($Docker) {
    Remove-Sidecar
    docker network create $name | Out-Null
    docker run -d --privileged --name $sidecar --network $name --network-alias dind `
        -v "${sidecar}:/var/lib/docker" $dindImage | Out-Null
    if ($LASTEXITCODE -ne 0) { Remove-Sidecar; throw 'Could not start the dind sidecar' }
    $ready = $false
    $ErrorActionPreference = 'Continue'  # docker info writes to stderr until the engine is up.
    for ($i = 0; $i -lt 60 -and -not $ready; $i++) {
        docker exec $sidecar docker -H tcp://127.0.0.1:2375 info 2>$null | Out-Null
        $ready = $LASTEXITCODE -eq 0
        if (-not $ready) { Start-Sleep -Milliseconds 500 }
    }
    $ErrorActionPreference = 'Stop'
    if (-not $ready) {
        $logs = docker logs --tail 20 $sidecar 2>&1 | Out-String
        Remove-Sidecar
        throw "The dind sidecar did not start. Last log lines:`n$logs"
    }
    $network = @('--network', $name)
    # Ryuk needs a socket bind mount, which the policy refuses. The sidecar
    # is removed after the session, which also removes the test containers.
    $envs += @('-e', 'DOCKER_HOST=tcp://dind:2375', '-e', 'TESTCONTAINERS_RYUK_DISABLED=true')
}

$dockerArgs = @('run', '--rm') + $tty + @(
    '--name', $name,
    '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
    '--memory', '8g', '--cpus', '4'
) + $network + $ports + $mounts + $envs + @($image) + $cmd

if ($env:AGENT_BOX_DEBUG) { Write-Host ('docker ' + ($dockerArgs -join ' ')) }
try {
    & docker @dockerArgs
    $exitCode = $LASTEXITCODE
}
finally {
    # Skipped when the terminal is killed. The next start removes leftovers.
    if ($Docker) { Remove-Sidecar }
}
exit $exitCode
