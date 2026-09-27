Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ruleName = 'EpicVM Direct Streams Media UDP 40900-41199'
$report = Join-Path $env:LOCALAPPDATA 'EpicVM\direct-streams\firewall-install-result.txt'

try {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) {
        # streamer.exe lives under each route; keep the legacy rule for old VM routes.
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
            -Protocol UDP -LocalPort '40900-41199' -Profile Any | Out-Null
    }
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
    $port = $rule | Get-NetFirewallPortFilter
    if ($rule.Enabled -ne 'True' -or $rule.Action -ne 'Allow' -or
        $port.Protocol -ne 'UDP' -or $port.LocalPort -ne '40900-41199') {
        throw 'The direct stream media firewall rule does not match the required range.'
    }
    Set-Content -LiteralPath $report -Value 'ok' -Encoding ascii
    Write-Host 'EpicVM direct stream UDP firewall rule installed.'
}
catch {
    Set-Content -LiteralPath $report -Value ('failed: ' + $_.Exception.Message) -Encoding ascii
    Write-Error $_
}
