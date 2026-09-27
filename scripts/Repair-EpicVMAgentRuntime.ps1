#Requires -Version 7.0
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\ProgramData\EpicVM\agent',
    [Parameter(Mandatory)][string]$ReportPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\remote_agent\windows\ServiceRuntime.ps1')
$serviceName = 'EpicVMRemoteAgent'
$parametersPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\EpicVMRemoteAgent\Parameters'
$before = [string](Get-ItemProperty -LiteralPath $parametersPath).Application
$changed = $false
try {
    $runtime = Resolve-EpicVMServiceRuntime -InstallRoot $InstallRoot
    if ((Get-Service -Name $serviceName).Status -ne 'Stopped') { Stop-Service -Name $serviceName -ErrorAction Stop }
    Set-ItemProperty -LiteralPath $parametersPath -Name Application -Value $runtime
    $changed = $true
    Start-Service -Name $serviceName -ErrorAction Stop
    $config = Get-Content -LiteralPath (Join-Path $InstallRoot 'config.json') -Raw | ConvertFrom-Json
    $headers = @{ Authorization = 'Bearer ' + (Get-Content -LiteralPath $config.TokenFile -Raw).Trim() }
    $healthy = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $health = Invoke-RestMethod -Uri ('http://{0}:{1}/v1/health' -f $config.BindAddress,$config.Port) -Headers $headers -TimeoutSec 2
            if ($health.ok) { $healthy = $true; break }
        } catch { Start-Sleep -Seconds 1 }
    }
    if (-not $healthy) { throw 'The agent did not pass its authenticated health check.' }
    @{ok=$true;previousRuntime=$before;runtime=$runtime;serviceStatus=[string](Get-Service $serviceName).Status;healthVerified=$healthy} |
        ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding utf8
}
catch {
    if ($changed) {
        Stop-Service -Name $serviceName -ErrorAction SilentlyContinue
        Set-ItemProperty -LiteralPath $parametersPath -Name Application -Value $before
    }
    @{ok=$false;error='agent_runtime_repair_failed';errorType=$_.Exception.GetType().Name} |
        ConvertTo-Json | Set-Content -LiteralPath $ReportPath -Encoding utf8
    exit 1
}
finally { $headers = $null }
