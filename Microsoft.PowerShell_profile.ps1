# TerminalBootstrap v1.1
# https://github.com/SemperFu/TerminalBootstrap

# --- Status output helper ---
function Write-Status {
    param(
        [ValidateSet("ok","warn","info","error","progress")]
        [string]$Type,
        [string]$Message,
        [switch]$Silent
    )
    if ($Type -eq "ok" -and ($Silent -or $script:silent)) { return }
    switch ($Type) {
        "ok"       { Write-Host "  [ok] " -ForegroundColor Green -NoNewline;     Write-Host $Message -ForegroundColor Green }
        "warn"     { Write-Host "  [!!] " -ForegroundColor Yellow -NoNewline;    Write-Host $Message -ForegroundColor Yellow }
        "info"     { Write-Host "  [^^] " -ForegroundColor Cyan -NoNewline;      Write-Host $Message -ForegroundColor Cyan }
        "error"    { Write-Host "  [!!] " -ForegroundColor Red -NoNewline;       Write-Host $Message -ForegroundColor Red }
        "progress" { Write-Host "  [>>] " -ForegroundColor Yellow -NoNewline;    Write-Host $Message -ForegroundColor DarkYellow }
    }
}

# --- Completion result helper ---
# Pipeline filter to convert strings to CompletionResult objects (used by tab completers below)
function Complete-Result { process { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) } }

$psMajor = $PSVersionTable.PSVersion.Major
$isPS7 = $psMajor -ge 7

# --- Configuration ---
# Loads bootstrap-config.json from the same directory as this script.
# If the file is missing, built-in defaults are used. If present, each top-level key overrides the default.
$script:config = @{
    silent = $false
    theme = $null
    packages = @(
        @{ id = "Microsoft.PowerShell";                                          install = $true;  update = $true;  silent = $false }
        @{ id = "JanDeDobbeleer.OhMyPosh";                                      install = $true;  update = $true;  silent = $false }
        @{ id = "nepnep.neofetch-win";                                           install = $false; update = $true;  silent = $true }
        @{ id = "Microsoft.WindowsTerminal";                                     install = $false; update = $true;  silent = $false }
    )
    cliProfiles = @(
        @{ name = "Copilot CLI"; cmd = "copilot"; iconFile = "Copilot.png" }
        @{ name = "Claude Code"; cmd = "claude";  iconFile = "ClaudeCode.png" }
    )
    modules = @(
        @{ name = "PSReadLine";          minVersion = "2.4.5"; minPS = 7; installParams = @{ SkipPublisherCheck = $true }; silent = $true }
        @{ name = "CompletionPredictor"; requires = @{ module = "PSReadLine"; minVersion = "2.2.6" }; silent = $true }
        @{ name = "PowerType";           requires = @{ module = "PSReadLine"; minVersion = "2.2.6" }; minPS = 7; installParams = @{ AllowPrerelease = $true }; silent = $true }
        @{ name = "GlyphShell";          minPS = 7; installParams = @{ Scope = 'CurrentUser' }; silent = $true }
        @{ name = "Terminal-Icons";      maxPS = 6; minVersion = "0.11.0"; installParams = @{ Scope = 'CurrentUser' }; silent = $true }
    )
}

$configPath = Join-Path $PSScriptRoot "bootstrap-config.json"
if (Test-Path $configPath) {
    try {
        $jsonConfig = Get-Content $configPath -Raw | ConvertFrom-Json
        foreach ($key in @('silent', 'theme', 'packages', 'cliProfiles', 'modules')) {
            if ($null -ne $jsonConfig.$key) {
                $val = $jsonConfig.$key
                # Convert JSON arrays of objects to arrays of hashtables for consistent downstream use
                if ($val -is [array]) {
                    $converted = @()
                    foreach ($item in $val) {
                        if ($item -is [PSCustomObject]) {
                            $ht = @{}
                            $item.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }
                            # Convert nested PSCustomObject (installParams, requires) to hashtables
                            foreach ($k in @($ht.Keys)) {
                                if ($ht[$k] -is [PSCustomObject]) {
                                    $nested = @{}
                                    $ht[$k].PSObject.Properties | ForEach-Object { $nested[$_.Name] = $_.Value }
                                    $ht[$k] = $nested
                                }
                            }
                            $converted += $ht
                        } else {
                            $converted += $item
                        }
                    }
                    $script:config[$key] = $converted
                } else {
                    $script:config[$key] = $val
                }
            }
        }
    } catch {
        Write-Status "error" "bootstrap-config.json is malformed, using defaults: $_"
    }
}
$script:silent = $script:config.silent

# --- Module management helper ---
# Handles check → install → update → import for PSGallery modules
# -MinPSVersion: skip install/update on older PS versions, just import what's there
function Initialize-Module {
    param(
        [string]$Name,
        [version]$MinVersion = $null,
        [int]$MinPSVersion = 0,
        [hashtable]$InstallParams = @{},
        [switch]$Silent
    )
    $canManage = $psMajor -ge $MinPSVersion
    $mod = Get-Module -ListAvailable -Name $Name | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $mod) {
        if ($canManage) {
            Write-Status "progress" "$Name installing..."
            try {
                Install-Module -Name $Name -Force -Repository PSGallery @InstallParams -ErrorAction Stop
                Write-Status "ok" "$Name installed"
            } catch {
                Write-Status "error" "$Name failed: $_"
                return
            }
        }
    } elseif ($canManage -and $MinVersion -and $mod.Version -lt $MinVersion) {
        Write-Status "info" "$Name $($mod.Version) < $MinVersion, updating..."
        try {
            Install-Module -Name $Name -Force -Repository PSGallery @InstallParams -ErrorAction Stop
            Write-Status "ok" "$Name updated (restart to load)"
        } catch {
            Write-Status "error" "$Name update failed: $_"
            return
        }
    } elseif ($mod) {
        Write-Status "ok" "$Name $($mod.Version)" -Silent:$Silent
    }
    Import-Module -Name $Name -Force -ErrorAction SilentlyContinue
}

# --- PS5 notice ---
if (-not $isPS7) {
    Write-Status "warn" "Running Windows PowerShell $($PSVersionTable.PSVersion) - open PowerShell 7 for full profile support."
}

# --- WinGet module bootstrap ---
Initialize-Module 'Microsoft.WinGet.Client' -Silent

# --- Package management ---

$anyInstalled = $false
$updatable = [System.Collections.ArrayList]@()
# Batch call - one Get-WinGetPackage instead of per-package, saves ~2s on startup
$allInstalled = Get-WinGetPackage -ErrorAction SilentlyContinue
foreach ($entry in $config.packages) {
    try {
        $ids = $entry.id
        # Resolve alternatives: if id is an array, check the batch results for each
        # Important: filter $allInstalled here, don't call Get-WinGetPackage -Id per alt (kills perf)
        if ($ids -is [array]) {
            $pkg = $null
            $installed = $null
            foreach ($alt in $ids) {
                $installed = $allInstalled | Where-Object { $_.Id -eq $alt }
                if ($installed) {
                    $pkg = $alt
                    break
                }
            }
            if (-not $pkg) { $pkg = $ids[0] }
        } else {
            $pkg = $ids
            $installed = $allInstalled | Where-Object { $_.Id -eq $pkg }
        }
        if (-not $installed) {
            if ($entry.install) {
                Write-Status "progress" "$pkg installing..."
                $result = Install-WinGetPackage -Id $pkg -MatchOption Equals -Force -ErrorAction SilentlyContinue
                if ($result.Status -eq "Ok") {
                    Write-Status "ok" "$pkg installed"
                    $anyInstalled = $true
                } else {
                    $err = $result.Status
                    if ($result.ExtendedErrorCode) { $err = $result.ExtendedErrorCode }
                    Write-Status "error" "$pkg failed: $err"
                }
            }
        } else {
            if ($installed.IsUpdateAvailable) {
                if ($entry.update) {
                    if ($entry.process -and (Get-Process -Name $entry.process -ErrorAction SilentlyContinue)) {
                        $availVer = if ($installed.AvailableVersions) { $installed.AvailableVersions[0] } else { "unknown" }
                        Write-Status "warn" "$pkg update skipped (in use) ($($installed.InstalledVersion) -> $availVer)"
                        continue
                    }
                    Write-Status "progress" "$pkg updating..."
                    $result = Update-WinGetPackage -Id $pkg -MatchOption Equals -Force -ErrorAction SilentlyContinue
                    if ($result.Status -eq "Ok") {
                        Write-Status "ok" "$pkg updated"
                    } else {
                        $err = $result.Status
                        if ($result.ExtendedErrorCode) { $err = $result.ExtendedErrorCode }
                        Write-Status "error" "$pkg update failed: $err"
                    }
                } else {
                    $updatable.Add($pkg) | Out-Null
                    $availVer = if ($installed.AvailableVersions) { $installed.AvailableVersions[0] } else { "unknown" }
                    Write-Status "info" "$pkg : $($installed.InstalledVersion) -> $availVer"
                }
            } else {
                Write-Status "ok" $pkg -Silent:($entry.silent -eq $true)
            }
        }
    } catch {
        Write-Status "error" "$pkg : $_"
    }
}

if ($anyInstalled) {
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
}

# --- Font management (requires oh-my-posh) ---
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    Add-Type -AssemblyName System.Drawing
    $fontInstalled = [bool]((New-Object System.Drawing.Text.InstalledFontCollection).Families |
                     Where-Object { $_.Name -eq "Cascadia Code NF" })
    if ($fontInstalled) {
        Write-Status "ok" "Cascadia Code NF" -Silent:$silent
    } else {
        Write-Status "progress" "Cascadia Code NF (MS) installing..."
        $fontResult = oh-my-posh font install "CascadiaCode (MS)" --headless 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Status "ok" "Cascadia Code NF (MS) installed - restart terminal to apply"
        } else {
            Write-Status "error" "Cascadia Code NF (MS) failed: $fontResult"
        }
    }
}

# --- Windows Terminal config (requires PowerShell 7+) ---
if ($isPS7) {
    function Update-WindowsTerminalSettings {
        param([string]$SettingsPath, [string]$EditionName)

        if (-not (Test-Path $SettingsPath)) {
            Write-Status "error" "Windows Terminal ($EditionName) settings.json not found - skipping"
            return
        }

        try {
            $wtSettings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        } catch {
            Write-Status "error" "Windows Terminal ($EditionName) settings.json is malformed - skipping"
            return
        }
        $profileList = [System.Collections.ArrayList]@($wtSettings.profiles.list)
        $pwsh        = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
        $changes     = [System.Collections.ArrayList]@()

        $ps7Guid     = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"

        # Font
        # Re-check font here (not reusing earlier check) because oh-my-posh may have just installed it
        $fontInstalled = [bool]((New-Object System.Drawing.Text.InstalledFontCollection).Families |
                         Where-Object { $_.Name -eq "Cascadia Code NF" })
        if ($fontInstalled) {
            if (-not $wtSettings.profiles.defaults.PSObject.Properties["font"]) {
                $wtSettings.profiles.defaults | Add-Member -NotePropertyName "font" -NotePropertyValue ([PSCustomObject]@{ face = "Cascadia Code NF" })
                $changes.Add("font set to Cascadia Code NF") | Out-Null
            } elseif ($wtSettings.profiles.defaults.font.face -ne "Cascadia Code NF") {
                $wtSettings.profiles.defaults.font.face = "Cascadia Code NF"
                $changes.Add("font updated to Cascadia Code NF") | Out-Null
            }
        }

        # Default profile
        if ($wtSettings.defaultProfile -ne $ps7Guid) {
            $wtSettings.defaultProfile = $ps7Guid
            $changes.Add("default profile set to PowerShell 7") | Out-Null
        }

        # CLI profiles - use custom icons if they exist next to the profile
        $iconDir         = Split-Path $PROFILE
        $defaultIcon     = "ms-appx:///ProfileIcons/$ps7Guid.scale-100.png"

        $presentCmds = @{}
        foreach ($cli in $config.cliProfiles) {
            $presentCmds[$cli.cmd] = [bool](Get-Command $cli.cmd -ErrorAction SilentlyContinue)
            $icon     = if (Test-Path "$iconDir\$($cli.iconFile)") { "$iconDir\$($cli.iconFile)" } else { $defaultIcon }
            $existing = $profileList | Where-Object { $_.name -eq $cli.name }

            if ($presentCmds[$cli.cmd] -and -not $existing) {
                $newGuid = "{$([guid]::NewGuid().ToString())}"
                $profileList.Add([PSCustomObject]@{
                    guid              = $newGuid
                    name              = $cli.name
                    commandline       = "`"$pwsh`" -c $($cli.cmd)"
                    hidden            = $false
                    icon              = $icon
                    colorScheme       = "Campbell"
                    startingDirectory = "%USERPROFILE%"
                }) | Out-Null
                $changes.Add("added $($cli.name) profile") | Out-Null
            }
        }

        $wtSettings.profiles.list = @($profileList)

        # New tab menu - always rebuild in memory; only written to disk when $changes has entries
        $menu = [System.Collections.ArrayList]@()
        $menu.Add([PSCustomObject]@{ type = "profile"; profile = $ps7Guid; icon = $null }) | Out-Null
        foreach ($cli in $config.cliProfiles) {
            if ($presentCmds[$cli.cmd]) {
                $cliGuid = ($profileList | Where-Object { $_.name -eq $cli.name }).guid
                $menu.Add([PSCustomObject]@{ type = "profile"; profile = $cliGuid; icon = $null }) | Out-Null
            }
        }
        $menu.Add([PSCustomObject]@{ type = "separator" }) | Out-Null
        $menu.Add([PSCustomObject]@{
            type       = "folder"
            name       = "Other"
            icon       = $null
            inline     = "never"
            allowEmpty = $false
            entries    = @([PSCustomObject]@{ type = "remainingProfiles" })
        }) | Out-Null
        $wtSettings.newTabMenu = @($menu)

        # Write only if changed
        if ($changes.Count -gt 0) {
            $wtSettings | ConvertTo-Json -Depth 10 | Set-Content $SettingsPath -Encoding UTF8
            Write-Status "info" "Windows Terminal ($EditionName) config updated:"
            foreach ($change in $changes) {
                Write-Host "       - $change" -ForegroundColor Cyan
            }
        } else {
            Write-Status "ok" "Windows Terminal ($EditionName) config" -Silent:$silent
        }
    }

    # Discover all installed WT editions by scanning Packages folder (no hardcoded publisher hash)
    $wtEditions = @()
    $wtPackageDirs = Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter "Microsoft.WindowsTerminal*" -ErrorAction SilentlyContinue
    foreach ($dir in $wtPackageDirs) {
        $settingsFile = Join-Path $dir.FullName "LocalState\settings.json"
        if (-not (Test-Path $settingsFile)) { continue }
        $editionName = switch -Wildcard ($dir.Name) {
            'Microsoft.WindowsTerminal_*'        { 'Stable' }
            'Microsoft.WindowsTerminalPreview_*' { 'Preview' }
            'Microsoft.WindowsTerminalCanary_*'  { 'Canary' }
            default {
                if ($dir.Name -match '^Microsoft\.WindowsTerminal([A-Za-z]+)_') { $Matches[1] } else { 'Unknown' }
            }
        }
        $wtEditions += @{ Name = $editionName; Path = $settingsFile; Folder = $dir.Name }
    }

    # Detect which edition is hosting this shell via process tree
    $activeFamily = $null
    $proc = Get-Process -Id $PID -ErrorAction SilentlyContinue
    while ($proc) {
        if ($proc.ProcessName -eq 'WindowsTerminal' -and $proc.Path -match '\\([^_\\]+)_[^_]+_[^_]+__([^\\]+)\\') {
            $activeFamily = "$($Matches[1])_$($Matches[2])"
            break
        }
        $proc = $proc.Parent
    }

    if ($wtEditions.Count -eq 0) {
        Write-Status "error" "No Windows Terminal editions found - skipping config"
    } else {
        foreach ($edition in $wtEditions) {
            $label = $edition.Name
            if ($activeFamily -and $edition.Folder -eq $activeFamily) { $label += ", active" }
            Update-WindowsTerminalSettings -SettingsPath $edition.Path -EditionName $label
        }
    }
}

# --- Modules (config-driven) ---
foreach ($mod in $config.modules) {
    # PS version gates
    if ($mod.minPS -and $psMajor -lt $mod.minPS) { continue }
    if ($mod.maxPS -and $psMajor -gt $mod.maxPS) { continue }
    # Dependency check
    if ($mod.requires) {
        $reqMod = Get-Module $mod.requires.module
        if (-not $reqMod) { continue }
        if ($mod.requires.minVersion -and $reqMod.Version -lt [version]$mod.requires.minVersion) { continue }
    }
    $params = @{ Name = $mod.name }
    if ($mod.minVersion)    { $params.MinVersion = [version]$mod.minVersion }
    if ($mod.minPS)         { $params.MinPSVersion = $mod.minPS }
    if ($mod.installParams) {
        # Convert PSCustomObject from JSON to hashtable (native hashtables pass through)
        if ($mod.installParams -is [hashtable]) {
            $params.InstallParams = $mod.installParams
        } else {
            $ip = @{}; $mod.installParams.PSObject.Properties | ForEach-Object { $ip[$_.Name] = $_.Value }
            $params.InstallParams = $ip
        }
    }
    if ($mod.silent) { $params.Silent = $true }
    Initialize-Module @params
}

# --- PSReadLine config ---
Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
$psrlVer = (Get-Module PSReadLine).Version
if ($psrlVer -and $psrlVer -ge [version]'2.2.6') {
    if (Get-Command Enable-PowerType -ErrorAction SilentlyContinue) { Enable-PowerType }
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle ListView
}
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

# --- Tab completions ---
# These just register a scriptblock - zero startup cost, only runs when you press Tab

# Batch Get-Command for all completion tools at once (~50ms total vs ~50ms each)
$cmds = @{}
Get-Command winget,dotnet,az,gh,kubectl,docker -ErrorAction SilentlyContinue | ForEach-Object { $cmds[$_.Name] = $true }

# Native completers - each tool has unique args so they need full blocks
if ($cmds['winget']) {
    Register-ArgumentCompleter -Native -CommandName winget -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        [Console]::InputEncoding = [Console]::OutputEncoding = $OutputEncoding = [System.Text.Utf8Encoding]::new()
        $Local:word = $wordToComplete.Replace('"', '""')
        $Local:ast = $commandAst.ToString().Replace('"', '""')
        winget complete --word="$Local:word" --commandline "$Local:ast" --position $cursorPosition | Complete-Result
    }
}

if ($cmds['dotnet']) {
    Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        dotnet complete --position $cursorPosition "$commandAst" 2>$null | Complete-Result
    }
}

if ($cmds['az']) {
    Register-ArgumentCompleter -Native -CommandName az -ScriptBlock {
        param($commandName, $wordToComplete, $cursorPosition)
        $completion_file = New-TemporaryFile
        $envVars = @{
            ARGCOMPLETE_USE_TEMPFILES    = 1
            _ARGCOMPLETE_STDOUT_FILENAME = $completion_file
            COMP_LINE                    = $wordToComplete
            COMP_POINT                   = $cursorPosition
            _ARGCOMPLETE                 = 1
            _ARGCOMPLETE_SUPPRESS_SPACE  = 0
            _ARGCOMPLETE_IFS             = "`n"
            _ARGCOMPLETE_SHELL           = 'powershell'
        }
        $envVars.GetEnumerator() | ForEach-Object { Set-Item "Env:\$($_.Key)" $_.Value }
        az 2>&1 | Out-Null
        Get-Content $completion_file | Sort-Object | Complete-Result
        Remove-Item $completion_file -ErrorAction SilentlyContinue
        $envVars.Keys | ForEach-Object { Remove-Item "Env:\$_" -ErrorAction SilentlyContinue }
    }
}

# Script completers - tool outputs a full completion script, just Invoke-Expression it
# To add a new tool: copy a line, change the tool name and completion command
if ($cmds['gh'])      { gh completion -s powershell      2>$null | Out-String | Invoke-Expression }
if ($cmds['kubectl']) { kubectl completion powershell     2>$null | Out-String | Invoke-Expression }
if ($cmds['docker'])  { docker completion powershell      2>$null | Out-String | Invoke-Expression }

# Print a copy-pasteable update command if anything needs updating (after all status lines)
if ($updatable.Count -gt 0) {
    Write-Host ""
    Write-Host "  To update these packages, copy and run:" -ForegroundColor DarkGray
    Write-Host "  winget update $($updatable -join ' ')" -ForegroundColor DarkYellow
    Write-Host ""
}

# --- Shell init ---
if (Get-Command oh-my-posh -ErrorAction SilentlyContinue) {
    if ($config.theme) {
        $themePath = $config.theme
        # Resolve relative file paths against $PSScriptRoot (theme names like "agnoster" pass through as-is)
        if ($themePath -match '\.' -and -not [System.IO.Path]::IsPathRooted($themePath)) {
            $themePath = Join-Path $PSScriptRoot $themePath
        }
        oh-my-posh init pwsh --config "$themePath" | Invoke-Expression
    } else {
        oh-my-posh init pwsh | Invoke-Expression
    }
}

if (Get-Command neofetch -ErrorAction SilentlyContinue) {
    neofetch
}
