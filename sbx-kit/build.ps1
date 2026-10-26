<#
.SYNOPSIS
Stage the host config into the agent-box sandbox kit and validate it.

.DESCRIPTION
Fills sbx-kit/files/home/ from the host:
- ~/.claude/skills, commands, plugins (cache and marketplaces, paths rewritten)
- ~/.claude/settings.json without hooks, status line and permission mode
- ~/.claude/CLAUDE.md with the sandbox note appended
- ~/.config/opencode/opencode.json with API keys replaced by env references
- git identity
Run it again after you change plugins, skills or settings on the host.
Then: sbx kit add <sandbox> .\sbx-kit
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$repo = Split-Path $root -Parent
$claudeDir = Join-Path $HOME '.claude'
$home_ = Join-Path $root 'files\home'
$assets = Join-Path $home_ '.local\share\agent-box'

function Convert-JsonFile {
    param([string]$Path)
    Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-JsonFile {
    param($Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 50
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-TextFile {
    param([string]$Text, [string]$Path)
    [System.IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Rewrite Windows config paths to the sandbox home.
function Convert-HostPath {
    param([string]$Text)
    $backslash = $claudeDir.Replace('\', '\\')
    $forward = $claudeDir.Replace('\', '/')
    $Text = $Text.Replace($backslash, '/home/agent/.claude').Replace($forward, '/home/agent/.claude')
    # The rest of each rewritten path still has JSON-escaped backslashes.
    return [regex]::Replace($Text, '/home/agent/\.claude(?:\\\\[^"\\]+)+', { param($m) $m.Value -replace '\\\\', '/' })
}

# --- reset ------------------------------------------------------------------

if (Test-Path (Join-Path $root 'files')) { Remove-Item (Join-Path $root 'files') -Recurse -Force }
New-Item -ItemType Directory -Force -Path $assets, (Join-Path $home_ '.claude\plugins'), (Join-Path $home_ '.config\opencode') | Out-Null

# --- assets used by install.sh ---------------------------------------------

foreach ($f in 'install.sh', 'agent-config.sh', 'claude-json.json') {
    Write-TextFile (Get-Content (Join-Path $root "assets\$f") -Raw) (Join-Path $assets $f)
}
Copy-Item (Join-Path $repo 'opencode-managed.json') (Join-Path $assets 'opencode-managed.json')

$name = git config --global user.name
$email = git config --global user.email
Write-TextFile "[user]`n`tname = $name`n`temail = $email`n" (Join-Path $assets 'gitconfig')

# settings.json without host-only keys. The permission mode stays the one the
# agent kit sets.
$settings = Convert-JsonFile (Join-Path $claudeDir 'settings.json')
foreach ($key in 'hooks', 'statusLine') {
    if ($settings.PSObject.Properties[$key]) { $settings.PSObject.Properties.Remove($key) }
}
if ($settings.permissions -and $settings.permissions.PSObject.Properties['defaultMode']) {
    $settings.permissions.PSObject.Properties.Remove('defaultMode')
}
# No prompt for --dangerously-skip-permissions, which Orca passes.
$settings | Add-Member -NotePropertyName skipDangerousModePermissionPrompt -NotePropertyValue $true -Force
$settings | Add-Member -NotePropertyName bypassPermissionsModeAccepted -NotePropertyValue $true -Force
Write-JsonFile $settings (Join-Path $assets 'claude-settings.json')

# --- Claude home -------------------------------------------------------------

$claudeMd = Get-Content (Join-Path $claudeDir 'CLAUDE.md') -Raw
$claudeMd += Get-Content (Join-Path $root 'assets\sandbox-instructions.md') -Raw
Write-TextFile $claudeMd (Join-Path $home_ '.claude\CLAUDE.md')

# Skills and commands. `synced` is Claude's own sync folder, not a skill.
Copy-Item (Join-Path $claudeDir 'skills') (Join-Path $home_ '.claude\skills') -Recurse -Exclude 'synced'
Remove-Item (Join-Path $home_ '.claude\skills\synced') -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path (Join-Path $claudeDir 'commands')) {
    Copy-Item (Join-Path $claudeDir 'commands') (Join-Path $home_ '.claude\commands') -Recurse
}

# Plugins: cache, marketplaces and the registries with rewritten paths.
Copy-Item (Join-Path $claudeDir 'plugins\cache') (Join-Path $home_ '.claude\plugins\cache') -Recurse
New-Item -ItemType Directory -Force -Path (Join-Path $home_ '.claude\plugins\marketplaces') | Out-Null
Get-ChildItem (Join-Path $claudeDir 'plugins\marketplaces') -Directory | Where-Object Name -notlike 'temp_*' | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $home_ ".claude\plugins\marketplaces\$($_.Name)") -Recurse
}
foreach ($f in 'installed_plugins.json', 'known_marketplaces.json') {
    $text = Get-Content (Join-Path $claudeDir "plugins\$f") -Raw -Encoding UTF8
    Write-TextFile (Convert-HostPath $text) (Join-Path $home_ ".claude\plugins\$f")
}

# --- opencode ----------------------------------------------------------------
# API keys become env references. spec.yaml declares a credential per
# provider, and the proxy injects the real key.

$opencode = Convert-JsonFile (Join-Path $HOME '.config\opencode\opencode.json')
foreach ($p in $opencode.provider.PSObject.Properties) {
    if ($p.Value.options -and $p.Value.options.PSObject.Properties['apiKey']) {
        $var = 'OPENCODE_API_KEY_' + ($p.Name.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
        $p.Value.options.apiKey = "{env:$var}"
    }
}

# The sandbox has no OAuth token for intility-id. Use the sbx MCP gateway,
# like Claude does. The proxy adds the token. The entry name stays the same,
# so the tool names still match the rules in opencode-managed.json.
if ($opencode.mcp -and $opencode.mcp.PSObject.Properties['intility-id']) {
    $opencode.mcp.'intility-id' = [pscustomobject]@{
        type    = 'remote'
        url     = 'http://mcp-gateway.docker.internal/mcp'
        headers = [pscustomobject]@{ Authorization = 'Bearer proxy-managed' }
        oauth   = $false
        enabled = $true
    }
}
Write-JsonFile $opencode (Join-Path $home_ '.config\opencode\opencode.json')

# --- validate ----------------------------------------------------------------

$sbx = Join-Path $env:LOCALAPPDATA 'DockerSandboxes\bin\sbx.exe'
if (-not (Test-Path $sbx)) { $sbx = 'sbx' }
& $sbx kit validate $root --offline
if ($LASTEXITCODE -ne 0) { throw "sbx kit validate failed" }
$size = [math]::Round((Get-ChildItem (Join-Path $root 'files') -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
Write-Host "Kit staged: $size MB in $root\files"
