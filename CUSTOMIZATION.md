# Customization

## Add Packages

Just add WinGet package IDs to the `$packages` array:

```powershell
$silent = $false  # global override: $true suppresses all [ok] lines
$packages = @(
    @{ Id = "Microsoft.PowerShell";                             Install = $true;  Update = $true;  Silent = $true }
    @{ Id = "JanDeDobbeleer.OhMyPosh";                          Install = $true;  Update = $true;  Silent = $true }
    @{ Id = @("GitHub.Copilot", "GitHub.Copilot.Prerelease");   Install = $true;  Update = $true;  Process = "copilot"; Silent = $true }
    @{ Id = "nepnep.neofetch-win";                              Install = $true;  Update = $false }
    @{ Id = "Microsoft.VisualStudioCode";                       Install = $false; Update = $true;  Process = "Code";    Silent = $true }
    @{ Id = "Git.Git";                                          Install = $true;  Update = $true }
)
```

Each entry supports these fields:

- **Id** - WinGet package ID (string or array of alternatives). Arrays check each in order - first match wins. First entry is the default install target if none are found.
- **Install** - `$true` to auto-install if missing, `$false` to skip
- **Update** - `$true` to auto-update, `$false` to just report available updates
- **Process** - optional process name to check before updating. If the process is in use, the update is skipped with a yellow warning instead of failing with a COM error. Useful for CLI tools you keep open in other tabs (Copilot, Claude, VS Code, etc).
- **Silent** - `$true` to suppress the `[ok]` status line for this package. Errors, warnings, installs, and updates always show regardless. Great for packages you don't need to see every startup.

The `$silent` variable above the array is a global override. Set it to `$true` and ALL `[ok]` lines are suppressed (packages, modules, fonts, Windows Terminal config). Module calls also accept `-Silent` individually via `Initialize-Module`.

## Add Tab Completions

There are two patterns depending on the tool.

For tools that output a completion script (most common - just copy a line and change the name):

```powershell
# Script completers - tool outputs a full completion script, just Invoke-Expression it
if (Get-Command terraform -EA 0) { terraform completion powershell 2>$null | Out-String | Invoke-Expression }
```

For tools that have a `complete` subcommand with custom args (less common):

```powershell
if (Get-Command mycli -ErrorAction SilentlyContinue) {
    Register-ArgumentCompleter -Native -CommandName mycli -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        mycli complete --position $cursorPosition "$commandAst" 2>$null | Complete-Result
    }
}
```

Check the tool's docs for which pattern it uses.

## Add Windows Terminal Profiles

Follow the Copilot/Claude pattern in `Update-WindowsTerminalSettings`. Add an entry to `$cliProfiles` with a `Name`, `Cmd`, and `IconFile` - the script matches existing profiles by name and generates a GUID automatically for new ones.
