# TerminalBootstrap v1.0
# https://github.com/SemperFu/TerminalBootstrap

# --- User config ---
# Packages: Id (string or array of alternatives), Install ($true = auto-install if missing), Update ($true = auto-update)
# Process: optional process name - if running, update is skipped (avoids failing on in-use binaries)
# Silent: $true to suppress [ok] output for this package (errors/warnings/updates always show)
$silent = $false  # global override: $true suppresses all [ok] lines regardless of per-item Silent
$packages = @(
    @{ Id = "Microsoft.PowerShell";                             Install = $true;  Update = $true;  Silent = $false }
    @{ Id = "JanDeDobbeleer.OhMyPosh";                          Install = $true;  Update = $true;  Silent = $false }
    @{ Id = @("GitHub.Copilot", "GitHub.Copilot.Prerelease");   Install = $true;  Update = $true;  Silent = $false; Process = "copilot" }
    @{ Id = "Microsoft.VCRedist.2015+.x64";                     Install = $true;  Update = $false; Silent = $true }
    @{ Id = "nepnep.neofetch-win";                              Install = $true;  Update = $true;  Silent = $true }
    @{ Id = "Microsoft.VisualStudioCode";                       Install = $false; Update = $true;  Silent = $false; Process = "Code" }
    @{ Id = "Microsoft.WindowsTerminal";                        Install = $false; Update = $true;  Silent = $false }
    @{ Id = "Anthropic.ClaudeCode";                             Install = $false; Update = $true;  Silent = $false; Process = "claude" }
    @{ Id = "GitHub.cli";                                       Install = $false; Update = $true;  Silent = $false }
)

# Windows Terminal CLI profiles: Name (matched in settings.json), Cmd, IconFile (next to $PROFILE)
$cliProfiles = @(
    @{ Name = "Copilot CLI"; Cmd = "copilot"; IconFile = "Copilot.png" }
    @{ Name = "Claude Code"; Cmd = "claude";  IconFile = "ClaudeCode.png" }
)

# Oh My Posh theme: set to a theme name or full path, or $null for the default theme
# Examples: "agnoster", "paradox", "$env:POSH_THEMES_PATH\paradox.omp.json"
$ompTheme = $null

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
foreach ($entry in $packages) {
    try {
        $ids = $entry.Id
        # Resolve alternatives: if Id is an array, check the batch results for each
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
            if ($entry.Install) {
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
                if ($entry.Update) {
                    if ($entry.Process -and (Get-Process -Name $entry.Process -ErrorAction SilentlyContinue)) {
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
                Write-Status "ok" $pkg -Silent:($entry.Silent -eq $true)
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
        $wtSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
        if (-not (Test-Path $wtSettingsPath)) {
            Write-Status "error" "Windows Terminal settings.json not found - skipping config"
            return
        }

        try {
            $wtSettings = Get-Content $wtSettingsPath -Raw | ConvertFrom-Json
        } catch {
            Write-Status "error" "Windows Terminal settings.json is malformed - skipping config"
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
        foreach ($cli in $cliProfiles) {
            $presentCmds[$cli.Cmd] = [bool](Get-Command $cli.Cmd -ErrorAction SilentlyContinue)
            $icon     = if (Test-Path "$iconDir\$($cli.IconFile)") { "$iconDir\$($cli.IconFile)" } else { $defaultIcon }
            $existing = $profileList | Where-Object { $_.name -eq $cli.Name }

            if ($presentCmds[$cli.Cmd] -and -not $existing) {
                $newGuid = "{$([guid]::NewGuid().ToString())}"
                $profileList.Add([PSCustomObject]@{
                    guid              = $newGuid
                    name              = $cli.Name
                    commandline       = "`"$pwsh`" -c $($cli.Cmd)"
                    hidden            = $false
                    icon              = $icon
                    colorScheme       = "Campbell"
                    startingDirectory = "%USERPROFILE%"
                }) | Out-Null
                $changes.Add("added $($cli.Name) profile") | Out-Null
            } elseif (-not $presentCmds[$cli.Cmd] -and $existing) {
                $profileList.Remove($existing)
                $changes.Add("removed $($cli.Name) profile (not installed)") | Out-Null
            }
        }

        $wtSettings.profiles.list = @($profileList)

        # New tab menu - always rebuild in memory; only written to disk when $changes has entries
        $menu = [System.Collections.ArrayList]@()
        $menu.Add([PSCustomObject]@{ type = "profile"; profile = $ps7Guid; icon = $null }) | Out-Null
        foreach ($cli in $cliProfiles) {
            if ($presentCmds[$cli.Cmd]) {
                $cliGuid = ($profileList | Where-Object { $_.name -eq $cli.Name }).guid
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
            $wtSettings | ConvertTo-Json -Depth 10 | Set-Content $wtSettingsPath -Encoding UTF8
            Write-Status "info" "Windows Terminal config updated:"
            foreach ($change in $changes) {
                Write-Host "       - $change" -ForegroundColor Cyan
            }
        } else {
            Write-Status "ok" "Windows Terminal config" -Silent:$silent
        }
    }
    Update-WindowsTerminalSettings
}

# --- PSReadLine ---
# Bump min version manually when needed (avoids slow Find-Module calls).
Initialize-Module 'PSReadLine' -MinVersion '2.4.5' -MinPSVersion 7 -InstallParams @{ SkipPublisherCheck = $true } -Silent

Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
$psrlVer = (Get-Module PSReadLine).Version
if ($psrlVer -and $psrlVer -ge [version]'2.2.6') {
    Initialize-Module 'CompletionPredictor' -Silent
    Initialize-Module 'PowerType' -MinPSVersion 7 -InstallParams @{ AllowPrerelease = $true } -Silent
    if (Get-Command Enable-PowerType -ErrorAction SilentlyContinue) { Enable-PowerType }
    Set-PSReadLineOption -PredictionSource HistoryAndPlugin
    Set-PSReadLineOption -PredictionViewStyle ListView
}
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward

# --- Directory Icons ---
# GlyphShell requires PS 7.5+; fall back to Terminal-Icons on PS5.
if ($isPS7) {
    Initialize-Module 'GlyphShell' -InstallParams @{ Scope = 'CurrentUser' } -Silent
} else {
    Initialize-Module 'Terminal-Icons' -MinVersion '0.11.0' -InstallParams @{ Scope = 'CurrentUser' } -Silent
}

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
    if ($ompTheme) {
        oh-my-posh init pwsh --config "$ompTheme" | Invoke-Expression
    } else {
        oh-my-posh init pwsh | Invoke-Expression
    }
}

if (Get-Command neofetch -ErrorAction SilentlyContinue) {
    neofetch
}
