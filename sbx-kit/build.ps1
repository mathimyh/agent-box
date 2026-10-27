<#
.SYNOPSIS
Stage the host config into the agent-box sandbox kit and validate it.

.DESCRIPTION
Fills sbx-kit/files/home/ from the host:
- allow-listed skills, commands and plugins (see allowlist.txt), with the
  plugin registries filtered and paths rewritten
- ~/.claude/settings.json: allow-listed keys only, without the permission mode
- ~/.config/opencode/AGENTS.md with the host-only blocks stripped, staged as
  ~/.claude/CLAUDE.md and ~/.config/opencode/AGENTS.md
- ~/.config/opencode/opencode.json with API keys replaced by env references
  and secret-bearing MCP fields dropped
- git identity
Then scans files/ for token patterns and stops the build on a match. The
error names the file only, never the value.
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

# Remove the host-only blocks from the shared agent rules. A block is wrapped
# in `<!-- agent-box: host-only -->` markers. The sandbox keeps the rest.
# Unbalanced markers throw: half a block would leak host rules.
function Remove-HostOnlyBlocks {
    param([string]$Text)
    $startMarker = '<!-- agent-box: host-only -->'
    $endMarker = '<!-- /agent-box: host-only -->'
    $start = [regex]::Matches($Text, [regex]::Escape($startMarker)).Count
    $end = [regex]::Matches($Text, [regex]::Escape($endMarker)).Count
    if ($start -ne $end) {
        throw "Unbalanced host-only markers: $start start markers, $end end markers"
    }
    $pattern = '(?s)[ \t]*' + [regex]::Escape($startMarker) + '\r?\n.*?' + [regex]::Escape($endMarker) + '[ \t]*(?:\r?\n)?'
    return [regex]::Replace($Text, $pattern, '')
}

# Claude settings: keep only allow-listed keys. Every other host key (for
# example env or apiKeyHelper) stays out of the sandbox.
function Convert-ClaudeSettings {
    param($Settings)
    $allowed = 'permissions', 'enabledPlugins', 'model', 'modelSettings'
    $out = [pscustomobject]@{}
    foreach ($key in $allowed) {
        if ($Settings.PSObject.Properties[$key]) {
            $out | Add-Member -NotePropertyName $key -NotePropertyValue $Settings.$key
        }
    }
    # The permission mode stays the one the agent kit sets.
    if ($out.permissions -and $out.permissions.PSObject.Properties['defaultMode']) {
        $out.permissions.PSObject.Properties.Remove('defaultMode')
    }
    return $out
}

# Files that hold a token pattern: GitHub PATs (classic and fine-grained),
# sk- API keys, a long Bearer value, an npmrc _authToken line. Short strings
# such as "Bearer proxy-managed" stay under the length bounds.
function Find-StagedToken {
    param([string]$Directory)
    $pattern = 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(?:ant-[A-Za-z0-9-]{20,}|proj-[A-Za-z0-9_-]{20,}|[A-Za-z0-9]{20,})|Bearer\s+[A-Za-z0-9._~+/=-]{20,}|_authToken'
    Get-ChildItem -LiteralPath $Directory -Recurse -File | Where-Object {
        [regex]::IsMatch([System.IO.File]::ReadAllText($_.FullName), $pattern)
    } | ForEach-Object { $_.FullName }
}

# Parse allowlist.txt: [skills], [commands] and [plugins] sections, one name
# per line. Blank lines and # comments are ignored.
function Get-SbxAllowlist {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Allow list not found: $Path" }
    $out = [pscustomobject]@{ skills = @(); commands = @(); plugins = @() }
    $section = $null
    foreach ($line in (Get-Content $Path -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $out.PSObject.Properties[$section]) { throw "Unknown allow list section: [$section]" }
            continue
        }
        if (-not $section) { throw "Allow list entry outside a section: $t" }
        $out.$section += $t
    }
    return $out
}

# Copy only the allowed entries from one host config folder. A listed entry
# that is missing on the host throws, so a typo cannot silently drop it.
function Copy-AllowedItems {
    param([string[]]$Items, [string]$SourceDir, [string]$TargetDir, [string]$Kind)
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    foreach ($item in $Items) {
        $src = Join-Path $SourceDir $item
        if (-not (Test-Path $src)) { throw "Allowed $Kind not found on the host: $item" }
        Copy-Item $src (Join-Path $TargetDir $item) -Recurse
    }
}

# Filter the host plugin config down to the allowed plugins. Returns the
# filtered installed_plugins registry object, the marketplaces those plugins
# need, and the cache folders (relative to plugins\cache) to stage. Registry
# entries keep all scopes: only the allow list decides what is staged.
function Select-AllowedPlugins {
    param($InstalledRegistry, [string[]]$AllowedPlugins, [string]$CacheRoot)
    $out = [pscustomobject]@{
        registry     = [pscustomobject]@{ version = $InstalledRegistry.version; plugins = [pscustomobject]@{} }
        marketplaces = @()
        cacheDirs    = @()
    }
    foreach ($key in $AllowedPlugins) {
        $prop = $InstalledRegistry.plugins.PSObject.Properties[$key]
        if (-not $prop) { throw "Allowed plugin not installed on the host: $key" }
        $out.registry.plugins | Add-Member -NotePropertyName $key -NotePropertyValue $prop.Value
        foreach ($entry in @($prop.Value)) {
            $path = $entry.installPath
            if (-not $path -or -not $path.StartsWith($CacheRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Allowed plugin installs outside the cache: $key ($path)"
            }
            $rel = $path.Substring($CacheRoot.Length).TrimStart('\', '/')
            if ($out.cacheDirs -notcontains $rel) { $out.cacheDirs += $rel }
        }
        $marketplace = $key.Substring($key.IndexOf('@') + 1)
        if ($out.marketplaces -notcontains $marketplace) { $out.marketplaces += $marketplace }
    }
    return $out
}

# --- reset ------------------------------------------------------------------

if (Test-Path (Join-Path $root 'files')) { Remove-Item (Join-Path $root 'files') -Recurse -Force }
New-Item -ItemType Directory -Force -Path $assets, (Join-Path $home_ '.claude\plugins'), (Join-Path $home_ '.config\opencode') | Out-Null

$allow = Get-SbxAllowlist (Join-Path $root 'allowlist.txt')

# --- assets used by install.sh ---------------------------------------------

foreach ($f in 'install.sh', 'agent-config.sh', 'claude-json.json') {
    Write-TextFile (Get-Content (Join-Path $root "assets\$f") -Raw) (Join-Path $assets $f)
}
Copy-Item (Join-Path $repo 'opencode-managed.json') (Join-Path $assets 'opencode-managed.json')

$name = git config --global user.name
$email = git config --global user.email
Write-TextFile "[user]`n`tname = $name`n`temail = $email`n" (Join-Path $assets 'gitconfig')

# settings.json: allow list only. The permission mode stays the one the
# agent kit sets.
$settings = Convert-ClaudeSettings (Convert-JsonFile (Join-Path $claudeDir 'settings.json'))
# Keep the enabledPlugins flags only for allowed plugins. The others are not
# staged, and a flag for a missing plugin would warn in every session. An
# empty result throws: it means the flag keys do not match the allow list.
if ($settings.enabledPlugins) {
    $keep = [pscustomobject]@{}
    foreach ($p in $settings.enabledPlugins.PSObject.Properties) {
        if ($allow.plugins -contains $p.Name) {
            $keep | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
    if ($keep.PSObject.Properties.Count -eq 0) {
        throw 'enabledPlugins names no allowed plugin. Check the plugin keys in allowlist.txt against the host settings.'
    }
    $settings.enabledPlugins = $keep
}
# Orca starts Claude with --dangerously-skip-permissions. The two flags
# suppress the acceptance prompt for bypass mode, so an unattended worker
# does not stop at startup. See "Agent permissions" in docs/design.md.
$settings | Add-Member -NotePropertyName skipDangerousModePermissionPrompt -NotePropertyValue $true -Force
$settings | Add-Member -NotePropertyName bypassPermissionsModeAccepted -NotePropertyValue $true -Force
Write-JsonFile $settings (Join-Path $assets 'claude-settings.json')

# --- Claude home -------------------------------------------------------------

# The shared agent rules come from the opencode AGENTS.md, the source of truth
# for both host agents (the host ~/.claude/CLAUDE.md is a one-line @ import
# of it). The sandbox note is agentInstructions.content in spec.yaml: the
# engine writes it to the kit memory and links it from the generated AI file.
$agentsPath = Join-Path $HOME '.config\opencode\AGENTS.md'
if (-not (Test-Path $agentsPath)) {
    throw "Global agent rules not found: $agentsPath"
}
$sharedRules = Remove-HostOnlyBlocks (Get-Content $agentsPath -Raw -Encoding UTF8)
Write-TextFile $sharedRules (Join-Path $home_ '.claude\CLAUDE.md')
Write-TextFile $sharedRules (Join-Path $home_ '.config\opencode\AGENTS.md')

# Skills and commands: the allow list decides. `synced` (Claude's own sync
# folder), the trash folder and everything else not listed stay on the host.
Copy-AllowedItems $allow.skills (Join-Path $claudeDir 'skills') (Join-Path $home_ '.claude\skills') 'skill'
if (Test-Path (Join-Path $claudeDir 'commands')) {
    Copy-AllowedItems $allow.commands (Join-Path $claudeDir 'commands') (Join-Path $home_ '.claude\commands') 'command'
}

# Plugins: the allowed plugins, only the cache versions their registry
# entries point at, and only the marketplaces they need. The registries are
# filtered to match, so the sandbox sees no reference to what stayed out.
$installed = Convert-JsonFile (Join-Path $claudeDir 'plugins\installed_plugins.json')
$cacheRoot = Join-Path $claudeDir 'plugins\cache'
$selection = Select-AllowedPlugins $installed $allow.plugins $cacheRoot
New-Item -ItemType Directory -Force -Path (Join-Path $home_ '.claude\plugins\cache'), (Join-Path $home_ '.claude\plugins\marketplaces') | Out-Null
foreach ($rel in $selection.cacheDirs) {
    $src = Join-Path $cacheRoot $rel
    if (-not (Test-Path $src)) { throw "Allowed plugin cache folder not found on the host: $rel" }
    $target = Join-Path $home_ ".claude\plugins\cache\$rel"
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Copy-Item $src $target -Recurse
}
foreach ($m in $selection.marketplaces) {
    $src = Join-Path $claudeDir "plugins\marketplaces\$m"
    if (-not (Test-Path $src)) { throw "Marketplace folder not found on the host: $m" }
    Copy-Item $src (Join-Path $home_ ".claude\plugins\marketplaces\$m") -Recurse
}
$known = Convert-JsonFile (Join-Path $claudeDir 'plugins\known_marketplaces.json')
$knownOut = [pscustomobject]@{}
foreach ($m in $selection.marketplaces) {
    $prop = $known.PSObject.Properties[$m]
    if (-not $prop) { throw "Allowed marketplace missing from known_marketplaces.json: $m" }
    $knownOut | Add-Member -NotePropertyName $m -NotePropertyValue $prop.Value
}
Write-TextFile (Convert-HostPath ($selection.registry | ConvertTo-Json -Depth 50)) (Join-Path $home_ '.claude\plugins\installed_plugins.json')
Write-TextFile (Convert-HostPath ($knownOut | ConvertTo-Json -Depth 50)) (Join-Path $home_ '.claude\plugins\known_marketplaces.json')

# --- opencode ----------------------------------------------------------------
# API keys become env references. spec.yaml declares a credential per
# provider, and the proxy injects the real key.

$opencode = Convert-JsonFile (Join-Path $HOME '.config\opencode\opencode.json')
foreach ($p in $opencode.provider.PSObject.Properties) {
    if ($p.Value.options -and $p.Value.options.PSObject.Properties['apiKey']) {
        $var = 'OPENCODE_API_KEY_' + ($p.Name.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
        $p.Value.options.apiKey = "{env:$var}"
    }
    # Custom providers can send headers with a token. Drop them: opencode
    # does not expand {env:} there.
    if ($p.Value.options -and $p.Value.options.PSObject.Properties['headers']) {
        $p.Value.options.PSObject.Properties.Remove('headers')
    }
}

# MCP secrets: headers and environment hold tokens in plain text. Drop both,
# so an unknown MCP entry fails closed instead of leaking its credentials.
if ($opencode.mcp) {
    foreach ($m in $opencode.mcp.PSObject.Properties) {
        foreach ($key in 'headers', 'environment') {
            if ($m.Value -and $m.Value.PSObject.Properties[$key]) {
                $m.Value.PSObject.Properties.Remove($key)
            }
        }
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

# --- scan ---------------------------------------------------------------------
# Stop the build when a staged file holds a token pattern. The error names
# the file only, never the matched value.

$hits = Find-StagedToken (Join-Path $root 'files')
if ($hits) {
    $names = @($hits) | ForEach-Object { $_.Substring($root.Length + 1) }
    throw "Token pattern found in staged files:`n$($names -join "`n")"
}

# --- validate ----------------------------------------------------------------

$sbx = Join-Path $env:LOCALAPPDATA 'DockerSandboxes\bin\sbx.exe'
if (-not (Test-Path $sbx)) { $sbx = 'sbx' }
& $sbx kit validate $root --offline
if ($LASTEXITCODE -ne 0) { throw "sbx kit validate failed" }
$size = [math]::Round((Get-ChildItem (Join-Path $root 'files') -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
Write-Host "Kit staged: $size MB in $root\files"
