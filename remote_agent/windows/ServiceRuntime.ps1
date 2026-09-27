# Keep the LocalSystem service independent of Store updates and user app aliases.
function Test-EpicVMServiceRuntime {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -match '(?i)[\\/]WindowsApps[\\/]' -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $major = & $Path -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major' 2>$null
        return ($LASTEXITCODE -eq 0 -and [string]$major -eq '7')
    }
    catch { return $false }
}

function Resolve-EpicVMServiceRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$SourceHome = $PSHOME,
        [string]$MachineRuntime = (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')
    )
    $managedHome = Join-Path $InstallRoot 'pwsh7'
    $managedExe = Join-Path $managedHome 'pwsh.exe'
    foreach ($candidate in @($MachineRuntime, $managedExe)) {
        if (Test-EpicVMServiceRuntime -Path $candidate) { return $candidate }
    }
    # Install the complete current PowerShell distribution, not just pwsh.exe.
    # This also works when the installer itself was launched from the Store.
    if (-not (Test-Path -LiteralPath (Join-Path $SourceHome 'pwsh.exe') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $SourceHome 'System.Management.Automation.dll') -PathType Leaf)) {
        throw 'PowerShell 7 is required. Run this installer from a complete PowerShell 7 installation.'
    }
    $sourceFull = [IO.Path]::GetFullPath($SourceHome).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $targetFull = [IO.Path]::GetFullPath($managedHome).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($targetFull.StartsWith($sourceFull, [StringComparison]::OrdinalIgnoreCase) -or
        $sourceFull.StartsWith($targetFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The service runtime source and destination must be separate directories.'
    }
    New-Item -ItemType Directory -Path $managedHome -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $SourceHome -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $managedHome -Recurse -Force
    }
    if (-not (Test-EpicVMServiceRuntime -Path $managedExe)) {
        throw 'The installed PowerShell service runtime failed its version check.'
    }
    return $managedExe
}
