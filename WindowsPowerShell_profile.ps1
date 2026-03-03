# PS5 redirect — dot-sources the shared PS7 profile so both shells use the same config.
# Copy this file to: ~\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1
$ps7Profile = Join-Path ($PSScriptRoot -replace 'WindowsPowerShell$','PowerShell') 'Microsoft.PowerShell_profile.ps1'
if (Test-Path $ps7Profile) {
    . $ps7Profile
} else {
    Write-Host "  [!!] Shared profile not found: $ps7Profile" -ForegroundColor Yellow
}
