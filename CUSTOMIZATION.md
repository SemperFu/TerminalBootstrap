# Customization

All user-configurable values live in `bootstrap-config.json`, located in the same directory as the profile script. If the file is present, its values override the built-in defaults. If it's missing, the script works identically to having the shipped defaults.

The repo includes a `bootstrap-config.json` with the default configuration. Copy it next to your `$PROFILE` and edit to taste.

## Config File

```json
{
    "silent": false,
    "theme": null,
    "packages": [
        { "id": "Microsoft.PowerShell", "install": true, "update": true, "silent": false },
        { "id": "JanDeDobbeleer.OhMyPosh", "install": true, "update": true, "silent": false },
        ...
    ],
    "cliProfiles": [
        { "name": "Copilot CLI", "cmd": "copilot", "iconFile": "Copilot.png" },
        ...
    ],
    "modules": [
        { "name": "PSReadLine", "minVersion": "2.4.5", "minPS": 7, "installParams": { "SkipPublisherCheck": true }, "silent": true },
        ...
    ]
}
```

Each top-level key is independent - include only the keys you want to override. Missing keys keep their built-in defaults.

## Packages

Each entry in the `packages` array supports these fields:

- **id** - WinGet package ID (string or array of alternatives). Arrays check each in order - first match wins. First entry is the default install target if none are found.
- **install** - `true` to auto-install if missing, `false` to skip
- **update** - `true` to auto-update, `false` to just report available updates
- **process** - optional process name to check before updating. If the process is in use, the update is skipped with a yellow warning instead of failing with a COM error. Useful for CLI tools you keep open in other tabs (Copilot, Claude, VS Code, etc).
- **silent** - `true` to suppress the `[ok]` status line for this package. Errors, warnings, installs, and updates always show regardless.

The top-level `silent` field is a global override. Set it to `true` and all `[ok]` lines are suppressed everywhere.

### Example: add a package

```json
{
    "packages": [
        { "id": "Git.Git", "install": true, "update": true }
    ]
}
```

Note: the `packages` array replaces the default list entirely. Include all packages you want tracked, not just additions.

## Modules

Each entry in the `modules` array supports these fields:

- **name** - PSGallery module name
- **minVersion** - minimum version (triggers update if below)
- **minPS** - skip install/update below this PowerShell major version
- **maxPS** - skip entirely above this PowerShell major version (e.g. Terminal-Icons only on PS5)
- **installParams** - extra parameters passed to `Install-Module` (e.g. `{ "Scope": "CurrentUser" }`)
- **requires** - dependency check: `{ "module": "PSReadLine", "minVersion": "2.2.6" }`. Module is skipped if the dependency isn't loaded or is below the minimum version.
- **silent** - `true` to suppress the `[ok]` status line

Modules are processed in order. Put dependencies first (e.g. PSReadLine before CompletionPredictor).

## Theme

Set `theme` to an Oh My Posh theme name or full path. Use `null` for the default theme.

```json
{
    "theme": "agnoster"
}
```

## Windows Terminal CLI Profiles

Each entry in `cliProfiles` adds a Windows Terminal profile for a CLI tool:

- **name** - profile name in Windows Terminal (matched by name, not GUID)
- **cmd** - CLI command to run
- **iconFile** - icon filename (looked up next to `$PROFILE`, falls back to default PS7 icon)

## Tab Completions

Tab completions are not part of the config file since each tool has a unique completer pattern. To add a new completer, edit the script directly.

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
