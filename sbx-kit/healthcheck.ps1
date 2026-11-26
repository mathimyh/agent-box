<#
.SYNOPSIS
Check that an agent-box sandbox is healthy.

.DESCRIPTION
Verifies from the host that the sandbox exists, then runs all checks inside
it with one sbx exec: the build tools are on PATH, the git identity is set,
a repo is cloned, the nested docker daemon responds and the egress to
github.com works through the proxy.
Prints one FAIL line per problem and exits 1 when there is any, prints
"healthy" otherwise. A stopped sandbox is started first by sbx exec.
Example:
.\sbx-kit\healthcheck.ps1 -Name intility-id
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Name
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$sbx = Join-Path $env:LOCALAPPDATA 'DockerSandboxes\bin\sbx.exe'
if (-not (Test-Path $sbx)) { $sbx = 'sbx' }

# --- sandbox exists -----------------------------------------------------------

$line = @(& $sbx ls | Where-Object { ($_ -split '\s+')[0] -eq $Name })
if (-not $line) { throw "No sandbox named $Name in sbx ls." }
Write-Host $line

# --- in-sandbox checks (one exec) ----------------------------------------------

# Each check prints a line only when it fails, so empty output is healthy.
# The script is written without any double quote on purpose: PowerShell 5.1
# passes an argument with embedded quotes without wrapping it, which splits
# it into several arguments on the way to sbx. HOME must be forced: sbx exec
# -u agent does not set it, and git and npm resolve their config from it.
# `git config` without a scope because the sandbox sets a GIT_CONFIG env
# include that makes --global skip the files. The docker check needs a
# timeout: a broken nested dockerd hangs instead of failing.
$checks = 'HOME=/home/agent; export HOME; ' +
    'for t in dotnet node npm gh oc opencode docker; do command -v $t >/dev/null || echo tool missing: $t; done; ' +
    'git config user.name >/dev/null 2>&1 || echo git identity not set; ' +
    'ls -A /home/agent/repos 2>/dev/null | grep -q . || echo no repo cloned in /home/agent/repos; ' +
    'timeout 15 docker info >/dev/null 2>&1 || echo nested docker not responding; ' +
    'curl -sf -o /dev/null --max-time 15 https://github.com || echo no egress to github.com, proxy down?'

$problems = @(& $sbx exec -u agent $Name sh -c $checks | Where-Object { "$_" -ne '' })
if ($LASTEXITCODE -ne 0 -and $problems.Count -eq 0) {
    throw "sbx exec into $Name failed with exit code $LASTEXITCODE."
}
if ($problems) {
    $problems | ForEach-Object { Write-Host "FAIL  $_" }
    exit 1
}
Write-Host "$Name is healthy: tools, git identity, clone, nested docker and egress OK."
