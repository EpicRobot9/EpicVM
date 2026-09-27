#Requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$env:PSModulePath=(Join-Path $repo '.deps\powershell')+';'+$env:PSModulePath
Import-Module Pester -MinimumVersion 5.7.1 -Force
try {
    $result=Invoke-Pester -Path @(
        (Join-Path $repo 'remote_agent\windows\tests\GuestProvider.Tests.ps1'),
        (Join-Path $repo 'remote_agent\windows\tests\TailscaleProvider.Tests.ps1'),
        (Join-Path $repo 'remote_agent\windows\tests\Provisioning.Tests.ps1'),
        (Join-Path $repo 'remote_agent\windows\tests\OmarchyProvider.Tests.ps1'),
        (Join-Path $repo 'remote_agent\windows\tests\OmarchyTemplateBuilder.Tests.ps1'),
        (Join-Path $repo 'remote_agent\windows\tests\OmarchyHyperVProvider.Tests.ps1'),
        (Join-Path $repo 'remote_agent\windows\tests\OmarchyProvisioning.Tests.ps1')
    ) -Output None -PassThru
    [ordered]@{ok=($result.FailedCount -eq 0);passed=[int]$result.PassedCount;failed=[int]$result.FailedCount;skipped=[int]$result.SkippedCount;total=[int]$result.TotalCount}|ConvertTo-Json -Compress|Set-Content -LiteralPath $ReportPath -Encoding UTF8 -NoNewline
    if($result.FailedCount -gt 0){exit 1}
}
catch {
    [ordered]@{ok=$false;code='pester_runner_failed'}|ConvertTo-Json -Compress|Set-Content -LiteralPath $ReportPath -Encoding UTF8 -NoNewline
    exit 1
}
