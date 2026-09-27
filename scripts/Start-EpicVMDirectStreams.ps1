Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:LOCALAPPDATA 'EpicVM\direct-streams'
$supervisor = Join-Path $PSScriptRoot 'supervise_host_direct_streams.py'
if (-not (Test-Path -LiteralPath (Join-Path $root 'signing.key'))) {
    return
}

$existing = Get-CimInstance Win32_Process -Filter "name = 'python.exe' OR name = 'python3.13.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*supervise_host_direct_streams.py*' -and $_.CommandLine -like '*--watch*' }
if ($existing) {
    return
}

$python = (& py -3.13 -c 'import sys; print(sys.executable)').Trim()
Start-Process -FilePath $python -ArgumentList @($supervisor, $root, '--watch') `
    -WorkingDirectory $PSScriptRoot -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $root 'supervisor.out.log') `
    -RedirectStandardError (Join-Path $root 'supervisor.err.log')
