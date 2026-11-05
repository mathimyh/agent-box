<#
.SYNOPSIS
Create a new agent-box sandbox in one command.

.DESCRIPTION
Runs build.ps1 (stages the kit and revalidates it), then checks that every
credential the base and local kits declare has a stored global secret, and
stops with the missing names if not: a sandbox without them gets empty keys
at run time. Then creates the sandbox, prompts for the per-sandbox secrets
(the scoped GitHub token, plus the credentials a project kit declares) and
clones the repo to /home/agent/repos/<repo> with gh.
The GitHub token check is strict on purpose: only a secret scoped to this
sandbox counts. A global github secret must not silently give the sandbox
the host token.
The Orca steps cannot run from the CLI: the SSH target is added in the Orca
app. The script prints the exact commands with the values filled in.
Safe to run again after a partial failure: existing sandbox, set secrets and
cloned repo are detected and skipped.
Example:
.\sbx-kit\new-sandbox.ps1 -Name intility-id -Repo intility/intility-id -Kit intility-id -StaticMcp intility-id
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name,

    # Repository to clone, as owner/repo.
    [Parameter(Mandatory = $true)]
    [string]$Repo,

    # Project kit: a path, or a name under kits\.
    [string]$Kit,

    # Static MCP server names, passed to sbx create.
    [string[]]$StaticMcp
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$repo_ = Split-Path $root -Parent
$localKit = Join-Path $repo_ 'sbx-kit.local'
$sbx = Join-Path $env:LOCALAPPDATA 'DockerSandboxes\bin\sbx.exe'
if (-not (Test-Path $sbx)) { $sbx = 'sbx' }

function Invoke-Sbx {
    param([string[]]$Arguments)
    & $sbx @Arguments
    if ($LASTEXITCODE -ne 0) { throw "sbx $($Arguments -join ' ') failed" }
}

if ($Repo -notmatch '^[\w.-]+/[\w.-]+$') {
    throw "Repo must be owner/repo, got: $Repo"
}

# Kit argument: a path as given, or a name under kits\.
$kitPath = $null
if ($Kit) {
    if (Test-Path $Kit) {
        $kitPath = (Resolve-Path $Kit).Path
    } elseif (Test-Path (Join-Path $repo_ "kits\$Kit")) {
        $kitPath = Join-Path $repo_ "kits\$Kit"
    } else {
        throw "Project kit not found: $Kit (also tried kits\$Kit)"
    }
}

# Credential services a spec declares: one `- service: <name>` per entry.
function Get-SpecSecretServices {
    param([string]$SpecPath)
    $services = @()
    foreach ($m in [regex]::Matches((Get-Content $SpecPath -Raw -Encoding UTF8), '(?m)^\s*- service:\s*(\S+)\s*$')) {
        if ($services -notcontains $m.Groups[1].Value) { $services += $m.Groups[1].Value }
    }
    return $services
}

# sbx secret ls rows: SCOPE TYPE NAME SECRET. Service rows only.
function Get-SbxSecrets {
    $rows = @()
    foreach ($line in (& $sbx secret ls)) {
        $parts = "$line" -split '\s+'
        if ($parts.Count -ge 3 -and $parts[1] -eq 'service') {
            $rows += [pscustomobject]@{ Scope = $parts[0]; Service = $parts[2] }
        }
    }
    return $rows
}

# --- stage and pre-check ------------------------------------------------------

& (Join-Path $root 'build.ps1')

$expected = @(Get-SpecSecretServices (Join-Path $root 'spec.yaml')) +
    @(Get-SpecSecretServices (Join-Path $localKit 'spec.yaml'))
$globalServices = @((Get-SbxSecrets) | Where-Object { $_.Scope -eq '(global)' } | ForEach-Object { $_.Service })
$missing = @($expected | Where-Object { $globalServices -notcontains $_ })
if ($missing) {
    throw ("No global secret for kit credential: $($missing -join ', ').`n" +
        "Set each with: sbx secret set <name>`n" +
        'The create is stopped: the sandbox would get an empty key for it at run time.')
}

# --- create -------------------------------------------------------------------

$existing = @(& $sbx ls | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ -eq $Name })
if ($existing) {
    Write-Host "Sandbox $Name already exists, skipping the create."
} else {
    $createArgs = @('create', 'claude', '--name', $Name, '--kit', $root, '--kit', $localKit)
    if ($kitPath) { $createArgs += @('--kit', $kitPath) }
    if ($StaticMcp) { $createArgs += @('--static-mcp', ($StaticMcp -join ',')) }
    Invoke-Sbx $createArgs
}

# --- per-sandbox secrets ------------------------------------------------------

$needed = @('github')
if ($kitPath) { $needed += @(Get-SpecSecretServices (Join-Path $kitPath 'spec.yaml')) }
$secrets = Get-SbxSecrets
foreach ($svc in $needed) {
    # github counts only when scoped to this sandbox: a global github secret
    # would give every sandbox the host token. Kit credentials may sit in
    # either scope.
    $scopes = if ($svc -eq 'github') { @($Name) } else { @($Name, '(global)') }
    $has = @($secrets | Where-Object { $_.Service -eq $svc -and $scopes -contains $_.Scope })
    if ($has.Count -eq 0) {
        Write-Host "Secret $svc for $Name (the command asks for the value):"
        Invoke-Sbx @('secret', 'set', $svc, '--sandbox', $Name)
    }
}

# --- clone --------------------------------------------------------------------

$repoName = $Repo -replace '^.*/', ''
$cloned = & $sbx exec -u agent $Name sh -c "test -d /home/agent/repos/$repoName/.git"
if ($LASTEXITCODE -eq 0) {
    Write-Host "Repo already cloned at /home/agent/repos/$repoName, skipping the clone."
} else {
    Invoke-Sbx @('exec', '-u', 'agent', $Name, 'gh', 'repo', 'clone', $Repo, "/home/agent/repos/$repoName")
}

# --- Orca (manual) ------------------------------------------------------------

$projectKnown = $false
try {
    $projects = & orca project list
    if ($LASTEXITCODE -eq 0) { $projectKnown = (@($projects) -match [regex]::Escape("github:$Repo")).Count -gt 0 }
} catch { }

Write-Host @"
Sandbox $Name is ready. Finish the Orca setup (the SSH target is added in the app):
1. In Orca, add an SSH target with host $Name.sbx and user _default_user_
2. Take the environment id from: orca host list
3. orca project setup-existing-folder --project github:$Repo --host runtime:<environment-id> --path /home/agent/repos/$repoName --kind git
"@
if (-not $projectKnown) {
    Write-Host "Note: orca lists no project github:$Repo yet. It must exist there before step 3 succeeds."
}
