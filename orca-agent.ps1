# Orca agent command override (agentCmdOverrides in Orca's settings).
# Usage as override: <path>\orca-agent.cmd claude
# Orca appends its own args, for example --dangerously-skip-permissions.
#
# Agents in Orca worktrees (~\orca\workspaces\...) start in agent-box.
# All other calls run the agent on the host: Orca's --version check (it runs
# from the Orca install folder) and agents in main checkouts, such as the
# coordinator. See docs/design.md.

$agent = $args[0]
# Always an array. One string splats wrongly to a native command.
$rest = @($args | Select-Object -Skip 1)
$workspaces = Join-Path $HOME 'orca\workspaces\'
$cwd = (Get-Location).Path

if (-not $cwd.StartsWith($workspaces, [System.StringComparison]::OrdinalIgnoreCase)) {
    & $agent @rest
    exit $LASTEXITCODE
}

$launcher = Join-Path $PSScriptRoot 'agent-box.ps1'
try {
    & $launcher -Worktree $cwd -Agent $agent -AgentArgs $rest
}
catch {
    # Keep the error visible. Orca closes the pane when this process exits.
    Write-Host "agent-box: $_" -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}
