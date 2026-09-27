# Requires -Version 7.0
<#
    GPU-P helpers for disposable Gaming VMs.

    This file deliberately contains no standard-VM provisioning behavior.  It
    models the proven testre GPU-P recipe and is consumed by HyperVProvider.ps1
    only when the requested profile is Gaming.
#>

Set-StrictMode -Version Latest

function Get-EpicVMGamingProperty {
    param(
        [AllowNull()] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [AllowNull()] [object] $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $Object[$key]
            }
        }
        return $Default
    }
    foreach ($property in $Object.PSObject.Properties) {
        if ([string]::Equals($property.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $property.Value
        }
    }
    return $Default
}

function New-EpicVMGamingGpuError {
    param(
        [Parameter(Mandatory)] [string] $Code,
        [Parameter(Mandatory)] [string] $Message
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $Code -Force
    return $exception
}

function Get-EpicVMGamingGpuInstancePath {
    param([Parameter(Mandatory)] [object] $PartitionableGpu)

    $instancePath = [string](Get-EpicVMGamingProperty -Object $PartitionableGpu -Name 'InstancePath' -Default '')
    if ([string]::IsNullOrWhiteSpace($instancePath)) {
        $instancePath = [string](Get-EpicVMGamingProperty -Object $PartitionableGpu -Name 'Name' -Default '')
    }
    return $instancePath
}

function Resolve-EpicVMGamingPartitionableGpu {
    param(
        [Parameter(Mandatory)] [object[]] $PartitionableGpus,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DeviceIdentity
    )

    $matches = @($PartitionableGpus | Where-Object {
        $name = [string](Get-EpicVMGamingProperty -Object $_ -Name 'Name' -Default '')
        $instancePath = [string](Get-EpicVMGamingProperty -Object $_ -Name 'InstancePath' -Default '')
        $name.IndexOf($DeviceIdentity, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $instancePath.IndexOf($DeviceIdentity, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
    })

    if ($matches.Count -eq 0) {
        throw (New-EpicVMGamingGpuError -Code 'GpuIdentityUnavailable' -Message ("The GPU-P device identity '{0}' was not found." -f $DeviceIdentity))
    }
    if ($matches.Count -gt 1) {
        throw (New-EpicVMGamingGpuError -Code 'GpuIdentityAmbiguous' -Message ("Multiple matching partitionable GPUs were found for '{0}'." -f $DeviceIdentity))
    }

    $selected = $matches[0]
    $path = Get-EpicVMGamingGpuInstancePath -PartitionableGpu $selected
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw (New-EpicVMGamingGpuError -Code 'GpuIdentityUnavailable' -Message 'The matching partitionable GPU has no usable InstancePath.')
    }
    return $selected
}

function ConvertTo-EpicVMGamingQuotaValue {
    param(
        [AllowNull()] [object] $Value,
        [Parameter(Mandatory)] [string] $FieldName
    )

    try {
        $converted = [long][System.Convert]::ToInt64($Value)
    }
    catch {
        throw (New-EpicVMGamingGpuError -Code 'GpuQuotaUnavailable' -Message ("The GPU-P host quota '{0}' is invalid." -f $FieldName))
    }
    if ($converted -le 0) {
        throw (New-EpicVMGamingGpuError -Code 'GpuQuotaUnavailable' -Message ("The GPU-P host quota '{0}' is unavailable." -f $FieldName))
    }
    return $converted
}

function Get-EpicVMGamingQuotaMaximum {
    param(
        [Parameter(Mandatory)] [object] $PartitionableGpu,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ResourceName
    )

    # Hyper-V exposes the same host capacity under slightly different
    # property names across Windows builds and the proven testre helper.
    # Prefer the explicit partition maximum, then retain compatibility with
    # Partition*/resource/Total* fields without changing the quota semantics.
    foreach ($propertyName in @(
        "MaxPartition$ResourceName",
        "Partition$ResourceName",
        $ResourceName,
        "Total$ResourceName"
    )) {
        $value = Get-EpicVMGamingProperty -Object $PartitionableGpu -Name $propertyName -Default $null
        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) { continue }
        try {
            return ConvertTo-EpicVMGamingQuotaValue -Value $value -FieldName $propertyName
        }
        catch { continue }
    }
    throw (New-EpicVMGamingGpuError -Code 'GpuQuotaUnavailable' -Message ("The GPU-P host quota '{0}' is unavailable." -f $ResourceName))
}

function Get-EpicVMGamingGpuPartitionPlan {
    param(
        [Parameter(Mandatory)] [object] $PartitionableGpu,
        [Parameter(Mandatory)] [int] $Percent
    )

    if ($Percent -lt 1 -or $Percent -gt 100) {
        throw (New-EpicVMGamingGpuError -Code 'InvalidGpuPartitionPercent' -Message 'The GPU-P partition percentage must be between 1 and 100.')
    }

    $vram = Get-EpicVMGamingQuotaMaximum -PartitionableGpu $PartitionableGpu -ResourceName 'VRAM'
    $decode = Get-EpicVMGamingQuotaMaximum -PartitionableGpu $PartitionableGpu -ResourceName 'Decode'
    $compute = Get-EpicVMGamingQuotaMaximum -PartitionableGpu $PartitionableGpu -ResourceName 'Compute'
    $scale = {
        param([long]$Maximum)
        return [long][math]::Floor(([decimal]$Maximum * [decimal]$Percent) / 100D)
    }
    $vramValue = & $scale $vram
    $decodeValue = & $scale $decode
    $computeValue = & $scale $compute
    if ($vramValue -le 0 -or $decodeValue -le 0 -or $computeValue -le 0) {
        throw (New-EpicVMGamingGpuError -Code 'GpuQuotaUnavailable' -Message 'The requested GPU-P percentage produces an unusable quota.')
    }

    # testre uses the host maximum for encode, represented by the signed
    # Int64 value accepted by Set-VMGpuPartitionAdapter.  Do not scale it.
    $encodeValue = [long]::MaxValue
    $instancePath = Get-EpicVMGamingGpuInstancePath -PartitionableGpu $PartitionableGpu

    return [ordered]@{
        percent = [int]$Percent
        instancePath = $instancePath
        minPartitionVRAM = $vramValue
        maxPartitionVRAM = $vramValue
        optimalPartitionVRAM = $vramValue
        minPartitionDecode = $decodeValue
        maxPartitionDecode = $decodeValue
        optimalPartitionDecode = $decodeValue
        minPartitionCompute = $computeValue
        maxPartitionCompute = $computeValue
        optimalPartitionCompute = $computeValue
        minPartitionEncode = $encodeValue
        maxPartitionEncode = $encodeValue
        optimalPartitionEncode = $encodeValue
    }
}

function Invoke-EpicVMGamingGpuCopy {
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationPath,
        [AllowNull()] [scriptblock] $CopyInvoker = $null
    )

    if ($null -ne $CopyInvoker) {
        return & $CopyInvoker $SourcePath $DestinationPath
    }
    return Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Recurse -Force -ErrorAction Stop
}

function Get-EpicVMGamingMountedDriveRoot {
    param([Parameter(Mandatory)] [object] $MountedDisk)

    $rootPath = [string](Get-EpicVMGamingProperty -Object $MountedDisk -Name 'RootPath' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($rootPath)) {
        return $rootPath.TrimEnd([char]92, [char]47)
    }

    $driveLetter = [string](Get-EpicVMGamingProperty -Object $MountedDisk -Name 'DriveLetter' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($driveLetter)) {
        return ("{0}:\" -f $driveLetter.TrimEnd(':'))
    }

    $diskNumber = Get-EpicVMGamingProperty -Object $MountedDisk -Name 'Number' -Default $null
    if ($null -eq $diskNumber) {
        $diskNumber = Get-EpicVMGamingProperty -Object $MountedDisk -Name 'DiskNumber' -Default $null
    }
    if ($null -eq $diskNumber) {
        throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message 'The mounted gaming VHDX did not expose a disk number or drive letter.')
    }

    $disk = Get-Disk -Number ([int]$diskNumber) -ErrorAction Stop
    $partitions = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Where-Object { $_.DriveLetter })
    foreach ($partition in $partitions) {
        $candidateRoot = ([string]$partition.DriveLetter + ':\')
        if (Test-Path -LiteralPath (Join-Path $candidateRoot 'Windows\System32') -PathType Container) {
            return $candidateRoot.TrimEnd([char]92, [char]47)
        }
    }
    throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message 'The mounted gaming VHDX did not expose a Windows volume containing Windows\System32.')
}

function ConvertTo-EpicVMGamingDriverFileMappings {
    param(
        [Parameter(Mandatory)] [string[]] $SourcePaths,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $HostWindowsRoot
    )

    $windowsRoot = $HostWindowsRoot.TrimEnd([char]92, [char]47)
    $driverStoreRelative = 'System32\DriverStore\FileRepository\'
    $mappings = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($sourcePathValue in @($SourcePaths)) {
        $sourcePath = [string]$sourcePathValue
        if ([string]::IsNullOrWhiteSpace($sourcePath)) { continue }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { continue }

        $fullPath = [System.IO.Path]::GetFullPath($sourcePath)
        if (-not $fullPath.StartsWith($windowsRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $relativeFromWindows = $fullPath.Substring(($windowsRoot + '\').Length)
        $driverStoreIndex = $relativeFromWindows.IndexOf($driverStoreRelative, [System.StringComparison]::OrdinalIgnoreCase)
        if ($driverStoreIndex -ge 0) {
            $packageRelative = $relativeFromWindows.Substring($driverStoreIndex + $driverStoreRelative.Length)
            $separatorIndex = $packageRelative.IndexOf([char]92)
            if ($separatorIndex -lt 1) { continue }
            $packageName = $packageRelative.Substring(0, $separatorIndex)
            $packageRoot = Join-Path (Join-Path $windowsRoot 'System32\DriverStore\FileRepository') $packageName
            $key = 'dir:' + $packageRoot
            if ($seen.Add($key)) {
                $mappings.Add([pscustomobject]@{
                        SourcePath = $packageRoot
                        RelativeDestination = ('Windows\System32\HostDriverStore\FileRepository\' + $packageName)
                        IsDirectory = $true
                    })
            }
            continue
        }

        $key = 'file:' + $fullPath
        if ($seen.Add($key)) {
            $mappings.Add([pscustomobject]@{
                    SourcePath = $fullPath
                    RelativeDestination = ('Windows\' + $relativeFromWindows)
                    IsDirectory = $false
                })
        }
    }
    return @($mappings)
}

function ConvertFrom-EpicVMGamingWmiDependentPath {
    param([AllowNull()] [object] $Dependent)

    $text = [string]$Dependent
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $match = [regex]::Match($text, 'Name="(?<path>.*)"$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    $escapedSlash = [string]::Concat([char]92, [char]92)
    return $match.Groups['path'].Value.Replace($escapedSlash, [string][char]92)
}

function Resolve-EpicVMGamingGpuDriverFileMappings {
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DeviceIdentity
    )

    try {
        $devices = @(
            Get-PnpDevice -Class Display -ErrorAction Stop |
                Where-Object {
                    ([string]$_.InstanceId).IndexOf($DeviceIdentity, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    ([string]$_.FriendlyName).IndexOf('Radeon RX 6800 XT', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }
        )
    }
    catch {
        throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message ('Unable to enumerate the host AMD display device: ' + $_.Exception.Message))
    }
    if ($devices.Count -eq 0) {
        throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message ("The host AMD display device matching '{0}' was not found." -f $DeviceIdentity))
    }

    $deviceId = [string]$devices[0].InstanceId
    $paths = [System.Collections.Generic.List[string]]::new()
    try {
        $signedDriver = @(
            Get-WmiObject -Class Win32_PnPSignedDriver -ErrorAction Stop |
                Where-Object { [string]$_.DeviceID -ieq $deviceId }
        ) | Select-Object -First 1
        if ($null -ne $signedDriver) {
            $infName = [string]$signedDriver.InfName
            if (-not [string]::IsNullOrWhiteSpace($infName)) {
                $infPath = Join-Path $env:windir ('Inf\' + $infName)
                if (Test-Path -LiteralPath $infPath -PathType Leaf) { [void]$paths.Add($infPath) }
            }
        }

        $records = @(
            Get-WmiObject -Class Win32_PnPSignedDriverCIMDataFile -ErrorAction Stop |
                Where-Object {
                    $antecedent = ([string]$_.Antecedent -replace '\\\\', '\\')
                    ([string]$_.Antecedent).IndexOf($DeviceIdentity, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }
        )
        foreach ($record in $records) {
            $path = ConvertFrom-EpicVMGamingWmiDependentPath -Dependent (Get-EpicVMGamingProperty -Object $record -Name 'Dependent' -Default '')
            if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                [void]$paths.Add($path)
            }
        }
    }
    catch {
        throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message ('Unable to enumerate the host AMD driver files: ' + $_.Exception.Message))
    }

    $uniquePaths = @($paths.ToArray() | Select-Object -Unique)
    return ConvertTo-EpicVMGamingDriverFileMappings -SourcePaths $uniquePaths -HostWindowsRoot $env:windir
}

function Invoke-EpicVMGamingGpuDriverInjection {
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DiskPath,
        [Parameter(Mandatory)] [string[]] $DriverSourcePaths,
        [AllowNull()] [string] $DeviceIdentity = $null,
        [AllowNull()] [object[]] $DriverFileMappings = $null,
        [AllowNull()] [scriptblock] $MountInvoker = $null,
        [AllowNull()] [scriptblock] $DismountInvoker = $null,
        [AllowNull()] [scriptblock] $CopyInvoker = $null
    )

    if (@($DriverSourcePaths).Count -eq 0) {
        throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message 'No AMD driver package sources were configured for Gaming GPU-P.')
    }

    $mounted = $null
    $mountedPath = $DiskPath
    try {
        if ($null -ne $MountInvoker) {
            $mounted = & $MountInvoker $DiskPath
        }
        else {
            $mounted = Mount-VHD -Path $DiskPath -Passthru -ErrorAction Stop
        }
        if ($null -eq $mounted) {
            throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message 'The gaming guest VHDX could not be mounted.')
        }

        $driveRoot = Get-EpicVMGamingMountedDriveRoot -MountedDisk $mounted
        # GPU-P's guest loader expects the host packages below the same
        # FileRepository boundary used by Add-VMGpuPartitionAdapterFiles.psm1.
        # Copying directly into HostDriverStore leaves the virtual adapter on
        # Microsoft's vrd.inf and produces CM_PROB_FAILED_POST_START.
        $destinationRoot = Join-Path $driveRoot 'Windows\System32\HostDriverStore\FileRepository'
        New-Item -ItemType Directory -Path $destinationRoot -Force -ErrorAction Stop | Out-Null
        $copiedSources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($sourcePath in $DriverSourcePaths) {
            if ([string]::IsNullOrWhiteSpace($sourcePath) -or -not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
                throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message ("The AMD driver package source '{0}' is unavailable." -f $sourcePath))
            }
            Invoke-EpicVMGamingGpuCopy -SourcePath $sourcePath -DestinationPath $destinationRoot -CopyInvoker $CopyInvoker | Out-Null
            $copiedSources.Add([System.IO.Path]::GetFullPath($sourcePath)) | Out-Null
        }

        $mappings = @($DriverFileMappings)
        if ($mappings.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($DeviceIdentity)) {
            $mappings = @(Resolve-EpicVMGamingGpuDriverFileMappings -DeviceIdentity $DeviceIdentity)
        }
        $mappedCount = 0
        foreach ($mapping in $mappings) {
            $sourcePath = [string](Get-EpicVMGamingProperty -Object $mapping -Name 'SourcePath' -Default '')
            $relativeDestination = [string](Get-EpicVMGamingProperty -Object $mapping -Name 'RelativeDestination' -Default '')
            $isDirectory = [bool](Get-EpicVMGamingProperty -Object $mapping -Name 'IsDirectory' -Default $false)
            if ([string]::IsNullOrWhiteSpace($sourcePath) -or [string]::IsNullOrWhiteSpace($relativeDestination)) { continue }
            if ($isDirectory -and $copiedSources.Contains([System.IO.Path]::GetFullPath($sourcePath))) { continue }
            if ($isDirectory) {
                $destinationParent = Join-Path $driveRoot (Split-Path -Parent $relativeDestination)
                New-Item -ItemType Directory -Path $destinationParent -Force -ErrorAction Stop | Out-Null
                Invoke-EpicVMGamingGpuCopy -SourcePath $sourcePath -DestinationPath $destinationParent -CopyInvoker $CopyInvoker | Out-Null
            }
            else {
                $destinationPath = Join-Path $driveRoot $relativeDestination
                $destinationParent = Split-Path -Parent $destinationPath
                New-Item -ItemType Directory -Path $destinationParent -Force -ErrorAction Stop | Out-Null
                if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
                    Invoke-EpicVMGamingGpuCopy -SourcePath $sourcePath -DestinationPath $destinationPath -CopyInvoker $CopyInvoker | Out-Null
                }
            }
            $mappedCount++
        }

        return [ordered]@{
            ok = $true
            diskPath = $DiskPath
            destination = $destinationRoot
            sourceCount = $DriverSourcePaths.Count
            mappedFileCount = $mappedCount
        }
    }
    catch {
        if ($_.Exception.PSObject.Properties['ErrorCode']) { throw }
        throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message $_.Exception.Message)
    }
    finally {
        if ($null -ne $mounted) {
            try {
                if ($null -ne $DismountInvoker) {
                    & $DismountInvoker $mountedPath
                }
                else {
                    Dismount-VHD -Path $mountedPath -ErrorAction SilentlyContinue
                }
            }
            catch { }
        }
    }
}

function Resolve-EpicVMGamingGpuDriverSourcePaths {
    param(
        [AllowNull()] [object] $Config,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DeviceIdentity
    )

    $configured = @(
        @(Get-EpicVMGamingProperty -Object $Config -Name 'GamingDriverSourcePaths' -Default @()) |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($configured.Count -gt 0) {
        foreach ($path in $configured) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message ("The configured AMD driver package source '{0}' is unavailable." -f $path))
            }
        }
        return @($configured | Select-Object -Unique)
    }

    $root = [string](Get-EpicVMGamingProperty -Object $Config -Name 'GamingDriverStoreRoot' -Default '')
    if ([string]::IsNullOrWhiteSpace($root)) {
        $systemRoot = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { 'C:\Windows' } else { $env:SystemRoot }
        $root = Join-Path $systemRoot 'System32\DriverStore\FileRepository'
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message ("The AMD DriverStore root '{0}' is unavailable." -f $root))
    }

    $matches = foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
        $infFiles = @(Get-ChildItem -LiteralPath $directory.FullName -Filter '*.inf' -File -ErrorAction SilentlyContinue)
        foreach ($inf in $infFiles) {
            if (Select-String -LiteralPath $inf.FullName -Pattern $DeviceIdentity -SimpleMatch -Quiet -ErrorAction SilentlyContinue) {
                $directory.FullName
                break
            }
        }
    }
    $unique = @($matches | Select-Object -Unique)
    if ($unique.Count -eq 0) {
        throw (New-EpicVMGamingGpuError -Code 'DriverInjectionFailed' -Message ("No AMD driver package matching '{0}' was found in '{1}'." -f $DeviceIdentity, $root))
    }
    return $unique
}

function Get-EpicVMGamingGuestValidationScript {
    return {
        param($DeviceIdentity, $SunshineServiceName, $SunshineStatePaths, [bool]$RequireEncoder=$true)
        $ErrorActionPreference = 'Stop'
        $errors = [System.Collections.Generic.List[string]]::new()
        $diagnostics = [ordered]@{}
        $displayOk = $false
        $videoOk = $false
        $dxdiagOk = $false
        $webglOk = $false
        $webglHardwareOk = $false
        $renderFrameOk = $false
        $encoderOk = $false
        try {
            $displayDevices = @(Get-PnpDevice -Class Display -ErrorAction Stop)
            $displayOk = @($displayDevices | Where-Object {
                [string]$_.Status -ieq 'OK' -and
                (([string]$_.InstanceId).IndexOf([string]$DeviceIdentity, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                 ([string]$_.FriendlyName).IndexOf('Radeon RX 6800 XT', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
            }).Count -gt 0
            $diagnostics.displayDeviceCount = $displayDevices.Count
        }
        catch {
            $diagnostics.displayProbe = 'unavailable'
        }
        try {
            $videoControllers = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
            $videoOk = @($videoControllers | Where-Object {
                (([string]$_.Name).IndexOf('Radeon RX 6800 XT', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                 ([string]$_.PNPDeviceID).IndexOf([string]$DeviceIdentity, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and
                ([string]$_.Status -ieq 'OK' -or [string]$_.Status -eq '')
            }).Count -gt 0
            $diagnostics.videoControllerCount = $videoControllers.Count
        }
        catch {
            $diagnostics.videoProbe = 'unavailable'
        }
        if (-not $displayOk -or -not $videoOk) {
            $errors.Add('GPU-P guest display verification failed.')
        }

        $dxdiagPath = Join-Path $env:TEMP ('epicvm-gaming-dxdiag-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            $dxdiag = Get-Command dxdiag.exe -ErrorAction SilentlyContinue
            if ($null -ne $dxdiag) {
                & $dxdiag.Source /whql:off /t $dxdiagPath | Out-Null
                if (Test-Path -LiteralPath $dxdiagPath) {
                    $dxText = Get-Content -LiteralPath $dxdiagPath -Raw -ErrorAction SilentlyContinue
                    $dxdiagOk = $dxText.IndexOf('Radeon RX 6800 XT', [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                        $dxText.IndexOf('73BF', [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                }
            }
        }
        catch { $diagnostics.dxdiagProbe = 'failed' }
        finally { Remove-Item -LiteralPath $dxdiagPath -Force -ErrorAction SilentlyContinue }
        if (-not $dxdiagOk) { $errors.Add('dxdiag did not report the expected AMD GPU.') }

        $webglPath = Join-Path $env:TEMP ('epicvm-gaming-webgl-' + [guid]::NewGuid().ToString('N') + '.html')
        try {
            $webglHtml = '<!doctype html><html><body style="margin:0;background:#000"><canvas id="c" width="320" height="180"></canvas><div id="m"></div><script>const c=document.getElementById("c");const g=c.getContext("webgl2")||c.getContext("webgl");let r="";if(g){try{const i=g.getExtension("WEBGL_debug_renderer_info");r=i?g.getParameter(i.UNMASKED_RENDERER_WEBGL):"";g.viewport(0,0,c.width,c.height);g.clearColor(0.08,0.32,0.86,1);g.clear(g.COLOR_BUFFER_BIT);g.finish()}catch(e){}}document.getElementById("m").innerText="WEBGL_CONTEXT="+!!g+";WEBGL_RENDERER="+r;</script></body></html>'
            Set-Content -LiteralPath $webglPath -Value $webglHtml -Encoding UTF8 -NoNewline
            $edgePaths = @(
                @(
                    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
                    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }
            )
            if (@($edgePaths).Count -gt 0) {
                $edgeVariants = @(
                    # The AMD GPU-P path is already known to work without forcing
                    # Edge's explicit GPU blocklist bypass combined with D3D11
                    # makes the GPU process exit (exit code 34) after a reboot
                    # even though dxdiag and the interactive stream remain healthy.
                    @('--headless=new', '--disable-software-rasterizer', '--enable-gpu'),
                    @('--headless=new', '--disable-software-rasterizer', '--enable-gpu', '--use-angle=d3d11'),
                    @('--headless=new', '--enable-gpu', '--disable-features=CalculateNativeWinOcclusion', '--use-angle=d3d11'),
                    @('--headless=new', '--enable-gpu'),
                    @('--headless=new', '--enable-gpu', '--disable-features=CalculateNativeWinOcclusion')
                )
                # Edge's GPU process can report a transient invalid state while
                # the newly restarted GPU-P guest is bringing up its render
                # path. Retry the bounded variant sweep instead of declaring a
                # healthy AMD device unusable on the first sweep.
                $webglAttempts = 3
                for ($webglAttempt = 1; $webglAttempt -le $webglAttempts -and -not $webglOk; $webglAttempt++) {
                    $diagnostics.webglAttempt = $webglAttempt
                    foreach ($edgeVariant in $edgeVariants) {
                        $edgeProfilePath = Join-Path $env:TEMP ('epicvm-gaming-edge-' + [guid]::NewGuid().ToString('N'))
                        $edgeOutputPath = Join-Path $env:TEMP ('epicvm-gaming-edge-out-' + [guid]::NewGuid().ToString('N') + '.txt')
                        $edgeErrorPath = Join-Path $env:TEMP ('epicvm-gaming-edge-err-' + [guid]::NewGuid().ToString('N') + '.txt')
                        $edgeFramePath = Join-Path $env:TEMP ('epicvm-gaming-edge-frame-' + [guid]::NewGuid().ToString('N') + '.png')
                        $edgeProcess = $null
                        try {
                            New-Item -ItemType Directory -Path $edgeProfilePath -Force -ErrorAction Stop | Out-Null
                            $edgeArgs = @(
                                ('--user-data-dir=' + $edgeProfilePath),
                                '--no-first-run',
                                '--no-default-browser-check'
                            ) + @($edgeVariant) + @(
                                '--disable-extensions',
                                '--window-size=320,220',
                                ('--screenshot=' + $edgeFramePath),
                                '--dump-dom',
                                '--virtual-time-budget=5000',
                                ("file:///{0}" -f ($webglPath -replace '\\','/'))
                            )
                            $edgeProcess = Start-Process -FilePath $edgePaths[0] -ArgumentList $edgeArgs -RedirectStandardOutput $edgeOutputPath -RedirectStandardError $edgeErrorPath -PassThru -WindowStyle Hidden
                            $finished = $edgeProcess.WaitForExit(15000)
                            if (-not $finished) {
                                try { $edgeProcess.Kill($true) } catch { }
                                throw 'The bounded Edge WebGL probe timed out.'
                            }
                            $dom = if (Test-Path -LiteralPath $edgeOutputPath -PathType Leaf) { Get-Content -LiteralPath $edgeOutputPath -Raw -ErrorAction SilentlyContinue } else { '' }
                            $domText = [string]$dom
                            $webglContextOk = $domText -match '(?i)WEBGL_CONTEXT=true'
                            $webglRendererOk = $domText -match '(?i)(AMD Radeon RX 6800 XT|0x000073BF)'
                            $diagnostics.webglRendererOk = $webglRendererOk
                            $diagnostics.webglDomMarker = if (-not $webglContextOk) { 'hardware_false' } elseif (-not $webglRendererOk) { 'hardware_renderer_mismatch' } else { 'hardware_true' }
                            if ($webglContextOk -and $webglRendererOk) {
                                $webglHardwareOk = $true
                                $bitmap = $null
                                try {
                                    if (Test-Path -LiteralPath $edgeFramePath -PathType Leaf) {
                                        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
                                        $bitmap = [System.Drawing.Bitmap]::new($edgeFramePath)
                                        $sampleX = [Math]::Min([Math]::Max([int]($bitmap.Width / 2), 0), [Math]::Max($bitmap.Width - 1, 0))
                                        $sampleY = [Math]::Min([Math]::Max([int]($bitmap.Height / 2), 0), [Math]::Max($bitmap.Height - 1, 0))
                                        $pixel = $bitmap.GetPixel($sampleX, $sampleY)
                                        $frameLuma = [int]$pixel.R + [int]$pixel.G + [int]$pixel.B
                                        $renderFrameOk = $bitmap.Width -ge 64 -and $bitmap.Height -ge 64 -and $frameLuma -ge 60
                                        $diagnostics.renderFrameWidth = $bitmap.Width
                                        $diagnostics.renderFrameHeight = $bitmap.Height
                                        $diagnostics.renderFrameLuma = $frameLuma
                                    }
                                    else { $diagnostics.renderFrameProbe = 'screenshot_missing' }
                                }
                                catch { $diagnostics.renderFrameProbe = 'failed' }
                                finally {
                                    if ($null -ne $bitmap) { $bitmap.Dispose() }
                                }
                                $diagnostics.renderFrameOk = $renderFrameOk
                            }
                            if ($webglContextOk -and $webglRendererOk -and $renderFrameOk) {
                                $webglOk = $true
                                $diagnostics.webglVariant = ($edgeVariant -join ' ')
                                break
                            }
                        }
                        catch { $diagnostics.webglProbe = 'failed' }
                        finally {
                            Remove-Item -LiteralPath $edgeProfilePath -Recurse -Force -ErrorAction SilentlyContinue
                            Remove-Item -LiteralPath $edgeOutputPath -Force -ErrorAction SilentlyContinue
                            Remove-Item -LiteralPath $edgeErrorPath -Force -ErrorAction SilentlyContinue
                            Remove-Item -LiteralPath $edgeFramePath -Force -ErrorAction SilentlyContinue
                        }
                    }
                    if (-not $webglOk -and $webglAttempt -lt $webglAttempts) { Start-Sleep -Milliseconds 500 }
                }
            }
            else { $diagnostics.edge = 'not_found' }
        }
        catch { $diagnostics.webglProbe = 'failed' }
        finally { Remove-Item -LiteralPath $webglPath -Force -ErrorAction SilentlyContinue }
        if (-not $webglOk) {
            if (-not $webglHardwareOk) { $errors.Add('Edge/WebGL did not report hardware acceleration.') }
            else { $errors.Add('The guest GPU render probe produced no usable frame.') }
        }

        try {
            $service = Get-Service -Name ([string]$SunshineServiceName) -ErrorAction Stop
            $sunshineFiles = @($SunshineStatePaths) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath $_ -PathType Leaf) }
            $logPaths = @(
                'C:\ProgramData\Sunshine\config\sunshine.log',
                'C:\Program Files\Sunshine\config\sunshine.log'
            ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
            # Discovery is logged at startup. Repeated host polls can push it
            # out of a short tail before validation finishes. Stream the log
            # for the actual successful discovery line without reading the
            # credential-bearing Sunshine state into memory.
            $encoderPattern='(?i)Found (H\.264|HEVC) encoder:\s*\w+_amf\s*\[amdvce\]'
            $encoderFound=@($logPaths | Where-Object { Select-String -LiteralPath $_ -Pattern $encoderPattern -Quiet -ErrorAction SilentlyContinue }).Count -gt 0
            $encoderOk = ([string]$service.Status -ieq 'Running') -and $encoderFound
            $diagnostics.sunshineServiceRunning = ([string]$service.Status -ieq 'Running')
            $diagnostics.sunshineStateFileCount = $sunshineFiles.Count
        }
        catch { $diagnostics.sunshineProbe = 'failed' }
        if ($RequireEncoder -and -not $encoderOk) { $errors.Add('Sunshine did not report AMD hardware encoding.') }

        $failureDetailCode = $null
        $safeMarker = $null
        if (-not $displayOk -or -not $videoOk) { $failureDetailCode = 'GAMING_GPU_DEVICE_MISSING'; $safeMarker = 'EPICVM_GAMING_GPU_VALIDATION_FAILED' }
        elseif (-not $dxdiagOk) { $failureDetailCode = 'GAMING_GPU_DXDIAG'; $safeMarker = 'EPICVM_GAMING_GPU_VALIDATION_FAILED' }
        elseif (-not $webglOk) {
            if ($webglHardwareOk) { $failureDetailCode = 'GAMING_GPU_FRAME' } else { $failureDetailCode = 'GAMING_GPU_WEBGL' }
            $safeMarker = 'EPICVM_GAMING_GPU_VALIDATION_FAILED'
        }
        elseif ($RequireEncoder -and -not $encoderOk) { $failureDetailCode = 'GAMING_GPU_ENCODER'; $safeMarker = 'EPICVM_GAMING_ENCODER_UNAVAILABLE' }
        return [ordered]@{
            ok = ($errors.Count -eq 0)
            displayOk = $displayOk
            videoControllerOk = $videoOk
            dxdiagOk = $dxdiagOk
            webglOk = $webglOk
            renderFrameOk = $renderFrameOk
            sunshineEncoderOk = $encoderOk
            diagnostics = $diagnostics
            errors = @($errors)
            failureDetailCode = $failureDetailCode
            safeMarker = $safeMarker
        }
    }
}

function Get-EpicVMGamingVmSettings {
    return [ordered]@{
        LowMemoryMappedIoSpace = [long]3221225472
        HighMemoryMappedIoSpace = [long]34359738368
        GuestControlledCacheTypes = $true
        AutomaticStopAction = 'ShutDown'
        CheckpointType = 'Disabled'
        AutomaticCheckpointsEnabled = $false
    }
}
