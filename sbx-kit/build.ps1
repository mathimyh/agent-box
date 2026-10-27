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
  and the mcp section dropped
- git identity
A host file or allow-listed item that is missing on the host is skipped
with a warning and listed at the end, so a teammate with a different host
config gets a working kit. That list is the typo guard: an entry you did
not expect usually means a typo in allowlist.txt. The git identity must
exist.
Also writes sbx-kit.local/spec.yaml (not committed): one credential per
opencode provider that carries an API key, with its endpoint domain from the
host config. Stops when a provider has no credential with the matching env
name and domain.
Then scans files/ for token patterns and stops the build on a match. The
error names the file only, never the value.
Run it again after you change plugins, skills or settings on the host.
Then: sbx create claude --kit .\sbx-kit --kit .\sbx-kit.local
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$repo = Split-Path $root -Parent
$claudeDir = Join-Path $HOME '.claude'
$localKit = Join-Path $repo 'sbx-kit.local'
$home_ = Join-Path $root 'files\home'
$assets = Join-Path $home_ '.local\share\agent-box'
$script:skipped = New-Object System.Collections.Generic.List[string]

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

# Record a host file or allow-listed item that is missing. The build
# continues without it: a teammate with a different host config must pass.
# The summary at the end is the typo guard, so nothing drops silently.
function Add-Skipped {
    param([string]$Kind, [string]$Name)
    $script:skipped.Add("$($Kind): $Name")
    Write-Warning "Skipped $($Kind): $Name"
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
# that is missing on the host is skipped with a warning and listed in the
# build summary, so a teammate with a different host config passes. The
# summary is the typo guard: an allow list entry that is missing for you
# usually means a typo in allowlist.txt.
function Copy-AllowedItems {
    param([string[]]$Items, [string]$SourceDir, [string]$TargetDir, [string]$Kind)
    if (-not (Test-Path $SourceDir)) {
        foreach ($item in $Items) { Add-Skipped $Kind $item }
        return
    }
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    foreach ($item in $Items) {
        $src = Join-Path $SourceDir $item
        if (-not (Test-Path $src)) {
            Add-Skipped $Kind $item
            continue
        }
        Copy-Item $src (Join-Path $TargetDir $item) -Recurse
    }
}

# Filter the host plugin config down to the allowed plugins. Returns the
# filtered installed_plugins registry object, the marketplaces those plugins
# need, the cache folders (relative to plugins\cache) to stage, and the names
# of the plugins that were staged. Registry entries keep all scopes: only
# the allow list decides what is staged. A listed plugin that is not
# installed on the host is skipped with a warning, not an error.
function Select-AllowedPlugins {
    param($InstalledRegistry, [string[]]$AllowedPlugins, [string]$CacheRoot)
    $out = [pscustomobject]@{
        registry     = [pscustomobject]@{ version = $InstalledRegistry.version; plugins = [pscustomobject]@{} }
        marketplaces = @()
        cacheDirs    = @()
        staged       = @()
    }
    foreach ($key in $AllowedPlugins) {
        $prop = $InstalledRegistry.plugins.PSObject.Properties[$key]
        if (-not $prop) { Add-Skipped 'plugin' $key; continue }
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
        $out.staged += $key
    }
    return $out
}

# Rewrite the opencode provider API keys to env references and return one
# object per provider that carries an API key: the credential service, the
# env name and the endpoint domain. Custom provider headers are dropped:
# opencode does not expand {env:} there.
function Convert-ProviderApiKeys {
    param($Opencode)
    $providers = @()
    foreach ($p in $Opencode.provider.PSObject.Properties) {
        if ($p.Value.options -and $p.Value.options.PSObject.Properties['headers']) {
            $p.Value.options.PSObject.Properties.Remove('headers')
        }
        if ($p.Value.options -and $p.Value.options.PSObject.Properties['apiKey']) {
            $var = 'OPENCODE_API_KEY_' + ($p.Name.ToUpperInvariant() -replace '[^A-Z0-9]', '_')
            $base = $p.Value.options.baseURL
            $domain = $null
            if ($base) { try { $domain = ([uri]$base).Host } catch { } }
            if (-not $domain) {
                throw "opencode provider '$($p.Name)' has an apiKey but no baseURL. Its sandbox credential cannot be built."
            }
            $p.Value.options.apiKey = "{env:$var}"
            $providers += [pscustomobject]@{ Service = $p.Name; EnvName = $var; Domain = $domain }
        }
    }
    return $providers
}

# Build the spec of the local credential kit: one credential per provider
# that carries an API key, plus the network allow list for the endpoint
# domains. Written to sbx-kit.local/ (not committed), so the base kit carries
# no personal data. Same credential shape as sbx-kit/spec.yaml.
function New-LocalKitSpec {
    param($Providers)
    $head = @(
        '# Generated by sbx-kit/build.ps1 from the host opencode config. Not committed.',
        '# One credential per provider that carries an API key. The proxy',
        '# injects the real key into the endpoint domain. Set each value with:',
        '# sbx secret set <service> -t <key>',
        'schemaVersion: "2"',
        'kind: mixin',
        'name: agent-box-local',
        'version: "0.1.0"',
        'displayName: agent-box local credentials',
        'description: Personal opencode model endpoints, generated from the host config.'
    )
    if (-not $Providers) {
        return (($head + 'credentials: []') -join "`n") + "`n"
    }
    $lines = $head + @(
        '',
        'permissions:',
        '  network:',
        '    allow:'
    )
    foreach ($d in @($Providers | ForEach-Object Domain | Select-Object -Unique)) {
        $lines += "      - $d"
    }
    $lines += @(
        '',
        'credentials:'
    )
    foreach ($p in $Providers) {
        $lines += @(
            "  - service: $($p.Service)",
            "    description: opencode provider $($p.Service)",
            '    apiKey:',
            "      name: $($p.EnvName)",
            '      proxyManaged: true',
            '      inject:',
            "        - domain: $($p.Domain)",
            '          header: Authorization',
            '          scheme: bearer'
        )
    }
    return ($lines -join "`n") + "`n"
}

# Check that a kit spec declares a credential whose apiKey uses the env name
# of a provider and injects into its endpoint domain. One credential entry is
# one block: env name and domain must sit in the same block.
function Test-SpecCredential {
    param([string]$SpecPath, $Provider)
    $text = Get-Content -Path $SpecPath -Raw -Encoding UTF8
    $entries = [regex]::Matches($text, '(?ms)^  - service:.*?(?=^  - service:|^  #|^\S|\z)')
    foreach ($e in $entries) {
        if ($e.Value -match ('(?m)^\s+name: ' + [regex]::Escape($Provider.EnvName) + '\s*$') -and
            $e.Value -match ('(?m)^\s+- domain: ' + [regex]::Escape($Provider.Domain) + '\s*$')) {
            return $true
        }
    }
    return $false
}

# --- reset ------------------------------------------------------------------

if (Test-Path (Join-Path $root 'files')) { Remove-Item (Join-Path $root 'files') -Recurse -Force }
if (Test-Path $localKit) { Remove-Item $localKit -Recurse -Force }
# The plugins folders are created below, only when a plugin is staged, so a
# host without plugins stages no empty .claude\plugins tree.
New-Item -ItemType Directory -Force -Path $assets, (Join-Path $home_ '.claude'), (Join-Path $home_ '.config\opencode') | Out-Null

$allow = Get-SbxAllowlist (Join-Path $root 'allowlist.txt')

# --- assets used by install.sh ---------------------------------------------

foreach ($f in 'install.sh', 'agent-config.sh', 'claude-json.json') {
    # -Encoding UTF8: under PS 5.1 the default reads as ANSI and non-ASCII
    # text becomes mojibake in the sandbox.
    Write-TextFile (Get-Content (Join-Path $root "assets\$f") -Raw -Encoding UTF8) (Join-Path $assets $f)
}
Copy-Item (Join-Path $repo 'opencode-managed.json') (Join-Path $assets 'opencode-managed.json')

$name = git config --global user.name
$email = git config --global user.email
if (-not $name -or -not $email) {
    throw 'git identity not set on the host. The sandbox takes it from the host config. Run: git config --global user.name <name> and git config --global user.email <email>'
}
Write-TextFile "[user]`n`tname = $name`n`temail = $email`n" (Join-Path $assets 'gitconfig')

# --- Claude home -------------------------------------------------------------

# The shared agent rules come from the opencode AGENTS.md, the source of truth
# for both host agents (the host ~/.claude/CLAUDE.md is a one-line @ import
# of it). The sandbox note is agentInstructions.content in spec.yaml: the
# engine writes it to the kit memory and links it from the generated AI file.
$agentsPath = Join-Path $HOME '.config\opencode\AGENTS.md'
if (Test-Path $agentsPath) {
    $sharedRules = Remove-HostOnlyBlocks (Get-Content $agentsPath -Raw -Encoding UTF8)
    Write-TextFile $sharedRules (Join-Path $home_ '.claude\CLAUDE.md')
    Write-TextFile $sharedRules (Join-Path $home_ '.config\opencode\AGENTS.md')
} else {
    Add-Skipped 'host file' '~\.config\opencode\AGENTS.md'
}

# Skills and commands: the allow list decides. `synced` (Claude's own sync
# folder), the trash folder and everything else not listed stay on the host.
Copy-AllowedItems $allow.skills (Join-Path $claudeDir 'skills') (Join-Path $home_ '.claude\skills') 'skill'
Copy-AllowedItems $allow.commands (Join-Path $claudeDir 'commands') (Join-Path $home_ '.claude\commands') 'command'

# Plugins: the allowed plugins, only the cache versions their registry
# entries point at, and only the marketplaces they need. The registries are
# filtered to match, so the sandbox sees no reference to what stayed out.
# A host without the plugin config stages no plugins at all.
$stagedPlugins = @()
if (Test-Path (Join-Path $claudeDir 'plugins\installed_plugins.json')) {
    $installed = Convert-JsonFile (Join-Path $claudeDir 'plugins\installed_plugins.json')
    $cacheRoot = Join-Path $claudeDir 'plugins\cache'
    $selection = Select-AllowedPlugins $installed $allow.plugins $cacheRoot
    $stagedPlugins = @($selection.staged)
    if ($stagedPlugins.Count -gt 0) {
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
    }
} else {
    Add-Skipped 'host file' '~\.claude\plugins\installed_plugins.json'
}

# settings.json: allow-listed keys only. The permission mode stays the one
# the agent kit sets. Without the host file, only the two unattended-worker
# flags below are staged, so a worker still starts without a prompt. The
# enabledPlugins flags keep only the plugins staged above: a flag for a
# plugin that stayed on the host would warn in every session.
$settings = [pscustomobject]@{}
$settingsPath = Join-Path $claudeDir 'settings.json'
if (Test-Path $settingsPath) {
    $settings = Convert-ClaudeSettings (Convert-JsonFile $settingsPath)
} else {
    Add-Skipped 'host file' '~\.claude\settings.json'
}
if ($settings.enabledPlugins) {
    $keep = [pscustomobject]@{}
    foreach ($p in $settings.enabledPlugins.PSObject.Properties) {
        if ($stagedPlugins -contains $p.Name) {
            $keep | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value
        }
    }
    if ($keep.PSObject.Properties.Count -eq 0) {
        $settings.PSObject.Properties.Remove('enabledPlugins')
        Add-Skipped 'config key' 'enabledPlugins, no staged plugin has a flag'
    } else {
        $settings.enabledPlugins = $keep
    }
}
# Orca starts Claude with --dangerously-skip-permissions. The two flags
# suppress the acceptance prompt for bypass mode, so an unattended worker
# does not stop at startup. See "Agent permissions" in docs/design.md.
$settings | Add-Member -NotePropertyName skipDangerousModePermissionPrompt -NotePropertyValue $true -Force
$settings | Add-Member -NotePropertyName bypassPermissionsModeAccepted -NotePropertyValue $true -Force
Write-JsonFile $settings (Join-Path $assets 'claude-settings.json')

# --- opencode ----------------------------------------------------------------
# API keys become env references. The generated local kit declares a
# credential per provider, and the proxy injects the real key. Without a
# host opencode config, no opencode config is staged and the local kit is
# empty; opencode in the sandbox then runs on the managed config alone.

$providers = @()
$opencodePath = Join-Path $HOME '.config\opencode\opencode.json'
if (Test-Path $opencodePath) {
    $opencode = Convert-JsonFile $opencodePath
    $providers = Convert-ProviderApiKeys $opencode

    # The mcp section is not staged. Its entries point at the host's direct
    # server URLs, and their headers and environment can hold secrets in plain
    # text. The sandbox has no OAuth tokens for them. opencode reaches an MCP
    # server only through a project kit, which adds the sbx MCP gateway entry and
    # the permission rules for it. See the kits\ directory and "Project kits" in
    # docs/design.md.
    if ($opencode.PSObject.Properties['mcp']) {
        $opencode.PSObject.Properties.Remove('mcp')
    }
    Write-JsonFile $opencode (Join-Path $home_ '.config\opencode\opencode.json')
} else {
    Add-Skipped 'host file' '~\.config\opencode\opencode.json'
}

# --- local credential kit ------------------------------------------------------
# Personal model credentials are generated from the host config, so the base
# kit carries no personal endpoints and other users can use it unchanged.

New-Item -ItemType Directory -Force -Path $localKit | Out-Null
$localSpec = Join-Path $localKit 'spec.yaml'
Write-TextFile (New-LocalKitSpec $providers) $localSpec

# Every provider that carries an API key must have a credential, with the
# matching env name and domain, in the base spec or the local kit. A missing
# one gives an empty key at run time, so stop the build.
foreach ($p in $providers) {
    $declared = (Test-SpecCredential (Join-Path $root 'spec.yaml') $p) -or (Test-SpecCredential $localSpec $p)
    if (-not $declared) {
        throw "No credential for opencode provider '$($p.Service)': expected env name $($p.EnvName) and domain $($p.Domain) in sbx-kit\spec.yaml or sbx-kit.local\spec.yaml."
    }
}

# --- scan ---------------------------------------------------------------------
# Stop the build when a staged file holds a token pattern. The error names
# the file only, never the matched value.

$hits = Find-StagedToken (Join-Path $root 'files')
if ($hits) {
    $names = @($hits) | ForEach-Object { $_.Substring($root.Length + 1) }
    throw "Token pattern found in staged files:`n$($names -join "`n")"
}

# --- skipped summary ----------------------------------------------------------
# Everything the host did not have. Read it: an entry you did not expect
# usually means a typo in allowlist.txt or a host file you thought existed.

if ($script:skipped.Count -gt 0) {
    Write-Host ''
    Write-Host 'Skipped:'
    foreach ($s in $script:skipped) { Write-Host "  - $s" }
}

# --- validate ----------------------------------------------------------------

$sbx = Join-Path $env:LOCALAPPDATA 'DockerSandboxes\bin\sbx.exe'
if (-not (Test-Path $sbx)) { $sbx = 'sbx' }
# The project kits under kits\ are committed. Validate them too, so a spec
# grammar error fails the build and not the next sandbox create.
$kits = @($root, $localKit)
$kits += Get-ChildItem -LiteralPath (Join-Path $repo 'kits') -Directory | ForEach-Object { $_.FullName }
foreach ($kit in $kits) {
    & $sbx kit validate $kit --offline
    if ($LASTEXITCODE -ne 0) { throw "sbx kit validate failed for $kit" }
}
$size = [math]::Round((Get-ChildItem (Join-Path $root 'files') -Recurse -File | Measure-Object Length -Sum).Sum / 1MB)
Write-Host "Kit staged: $size MB in $root\files"
Write-Host "Local credential kit: $localKit"
