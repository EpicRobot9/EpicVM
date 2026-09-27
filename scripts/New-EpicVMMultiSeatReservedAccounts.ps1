#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
$apiKeyPath = 'C:\ProgramData\MultiSeat\api-key.txt'
if (-not (Test-Path -LiteralPath $apiKeyPath -PathType Leaf)) { throw 'MultiSeat API key is unavailable.' }
$key = (Get-Content -LiteralPath $apiKeyPath -Raw).Trim()
if (-not $key) { throw 'MultiSeat API key is empty.' }
$headers = @{'X-MultiSeat-Key'=$key}
$base = 'http://127.0.0.1:9550'
$auth = Invoke-RestMethod -Uri "$base/api/system/auth" -Headers $headers -TimeoutSec 15
if ($auth.authEnabled -ne $true) { throw 'MultiSeat API authentication is not enabled.' }
$names = @('EpicVM_indo','EpicVM_mari')
$accounts = @(Invoke-RestMethod -Uri "$base/api/accounts/" -Headers $headers -TimeoutSec 15)
$results = @()
foreach ($name in $names) {
    $existing = @($accounts | Where-Object { $_.username -ieq $name })
    if ($existing.Count -gt 1) { throw "Duplicate MultiSeat account record: $name" }
    if ($existing.Count -eq 1) {
        if ($existing[0].isManaged -ne $true) { throw "An unmanaged account already uses $name." }
        $status = 'already-exists'
    } else {
        $password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(48)) + 'aA1!'
        try {
            Invoke-RestMethod -Uri "$base/api/accounts/" -Method Post -Headers $headers -ContentType 'application/json' -Body (@{username=$name;password=$password} | ConvertTo-Json -Compress) -TimeoutSec 30 | Out-Null
            $status = 'created'
        } finally { $password = $null }
    }
    $results += [pscustomobject]@{accountName=$name;status=$status}
}
$verified = @(Invoke-RestMethod -Uri "$base/api/accounts/" -Headers $headers -TimeoutSec 15)
foreach ($result in $results) {
    $matches = @($verified | Where-Object { $_.username -ieq $result.accountName -and $_.isManaged -eq $true })
    if ($matches.Count -ne 1) { throw "MultiSeat account verification failed: $($result.accountName)" }
}
[IO.File]::WriteAllText($ReportPath, (ConvertTo-Json -InputObject $results -Depth 3))
