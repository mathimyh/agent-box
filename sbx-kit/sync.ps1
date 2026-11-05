<#
.SYNOPSIS
Sync the staged kit into a running sandbox, without a recreate.

.DESCRIPTION
Runs build.ps1, then copies files/home/ into the sandbox with sbx cp,
refreshes /etc/opencode/opencode.json, re-applies the project-kit opencode
patches and runs agent-config.sh again as the agent user. Clones, worktrees
and the Orca project setup stay.
sbx cp merges directories, it does not mirror them: a file removed from the
kit stays in the sandbox. Changes to spec.yaml, install.sh or the network
policy still need a full recreate (see "Change the kit" in README.md).
Running agents keep their loaded config; the new files reach the next agent
session.
Example:
.\sbx-kit\sync.ps1 -Name intility-id
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$home_ = Join-Path $root 'files\home'
$sbx = Join-Path $env:LOCALAPPDATA 'DockerSandboxes\bin\sbx.exe'
if (-not (Test-Path $sbx)) { $sbx = 'sbx' }

function Invoke-Sbx {
    param([string[]]$Arguments)
    & $sbx @Arguments
    if ($LASTEXITCODE -ne 0) { throw "sbx $($Arguments -join ' ') failed" }
}

& (Join-Path $root 'build.ps1')

# sbx cp places the source inside the destination directory, so each
# top-level folder of files/home merges into /home/agent/.
foreach ($item in (Get-ChildItem -LiteralPath $home_ -Force -Directory)) {
    Write-Host "sync: $($item.Name)"
    Invoke-Sbx @('cp', $item.FullName, "${Name}:/home/agent/")
}

# sbx cp writes as root: hand the files back to the agent user, as
# install.sh does.
Invoke-Sbx @('exec', '-u', 'root', $Name, 'chown', '-R', 'agent:agent',
    '/home/agent/.claude', '/home/agent/.config', '/home/agent/.local/share/agent-box')

# Refresh the managed opencode config, re-apply the project-kit patches on
# top, then rerun the agent-user config merge.
Invoke-Sbx @('exec', '-u', 'root', $Name, 'cp',
    '/home/agent/.local/share/agent-box/opencode-managed.json', '/etc/opencode/opencode.json')
Invoke-Sbx @('exec', '-u', 'root', $Name, 'sh', '/home/agent/.local/share/agent-box/opencode-repatch.sh')
Invoke-Sbx @('exec', '-u', 'agent', $Name, 'sh', '/home/agent/.local/share/agent-box/agent-config.sh')

Write-Host "Kit synced into $Name. The new config reaches the next agent session."
