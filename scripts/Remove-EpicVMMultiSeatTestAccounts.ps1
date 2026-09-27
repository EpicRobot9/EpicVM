# Removes only the test identities observed on this PC on 2026-09-23.
# Run in an elevated PowerShell session.
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an elevated PowerShell session.'
}

$machineSid = 'S-1-5-21-3239555024-3755565078-3835443485'
$accounts = [ordered]@{
    'evduo_probe'          = 1017
    'evseat_e64dfb57425ce' = 1021
    'evseat_1da996e3c220e' = 1022
    'evseat_11e74b766207b' = 1023
    'evseat_cd053b3afbb40' = 1024
}
$profileSids = @(1017, 1019, 1020, 1021, 1022, 1023, 1024) | ForEach-Object { "$machineSid-$_" }
$profiles = @(Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -in $profileSids })
if (@($profiles | Where-Object Loaded).Count) { throw 'A target account profile is loaded. Sign it out before cleanup.' }

# MultiSeat keeps a separate account catalog. Ask its authenticated API to
# retire managed seat accounts before removing any remaining Windows accounts.
$apiKeyPath = 'C:\ProgramData\MultiSeat\api-key.txt'
if (-not (Test-Path -LiteralPath $apiKeyPath)) { throw 'MultiSeat API key is unavailable.' }
$key = (Get-Content -LiteralPath $apiKeyPath -Raw).Trim()
$headers = @{'X-MultiSeat-Key'=$key}
$seats = @(Invoke-RestMethod 'http://127.0.0.1:9550/api/seats/' -Headers $headers -TimeoutSec 15)
if (@($seats | Where-Object { $_.accountName -in @($accounts.Keys) }).Count) {
    throw 'A target account still has a MultiSeat seat. End its session before cleanup.'
}
foreach ($name in $accounts.Keys) {
    $expectedSid = "$machineSid-$($accounts[$name])"
    $local = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if ($local -and $local.SID.Value -ne $expectedSid) { throw "Identity changed for $name; stopping." }
    if ($name -like 'evseat_*') {
        try {
            Invoke-RestMethod -Method Delete -Uri "http://127.0.0.1:9550/api/accounts/$name" -Headers $headers -TimeoutSec 15 | Out-Null
        } catch {
            $code = [int]$_.Exception.Response.StatusCode
            if ($code -ne 404) { throw "MultiSeat account removal failed for $name (HTTP $code)." }
        }
    }
    $local = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
    if ($local) { Remove-LocalUser -Name $name -ErrorAction Stop }
    Write-Output "Removed account: $name"
}
foreach ($profile in $profiles) {
    if ($profile.Loaded) { throw "Profile became loaded: $($profile.LocalPath)" }
    if ($profile.LocalPath -notmatch '^C:\\Users\\(evseat_[a-z0-9]+(?:\.000)?|evduo_probe)$') { throw "Unexpected profile path: $($profile.LocalPath)" }
    $remaining = Get-CimInstance Win32_UserProfile -Filter "SID='$($profile.SID)'"
    if ($remaining) {
        Remove-CimInstance -InputObject $remaining -ErrorAction Stop
        Write-Output "Removed profile: $($profile.LocalPath)"
    }
}
