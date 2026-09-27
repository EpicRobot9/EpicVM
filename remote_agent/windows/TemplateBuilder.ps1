#Requires -Version 7.0
<#
    Source-only EpicVM golden-image builder.

    The builder is intentionally opt-in (-Run).  It never runs against a VM
    merely because the script was loaded, and it never accepts a password as a
    plain command-line argument.  The source VM is stopped only for the
    export, the builder is attached to a Private Hyper-V switch, and the
    source is restarted in the finally block when it was originally running.
#>

[CmdletBinding()]
param(
    [switch] $Run,
    [string] $SourceVmName = 'testre',
    [string] $VmRoot = 'E:\EpicVM\vms',
    [string] $TemplateRoot = 'E:\EpicVM\templates',
    [string] $TemplateName = 'win11-25h2',
    [string] $WorkingRoot = 'E:\EpicVM\template-work',
    [string] $PrivateSwitchName = 'EpicVM-Template-Private',
    [string] $BuilderVmName = 'EpicVM-TemplateBuilder',
    [string] $BootstrapUser = 'EpicVMBootstrap',
    [string] $BootstrapCredentialPath = 'C:\ProgramData\EpicVM\agent\bootstrap.dpapi',
    [string] $SunshineVersion = '2026.516.143833',
    [string] $GuestTimeZoneId = [string][TimeZoneInfo]::Local.Id,
    [switch] $UseCleanTemplateSource,
    [string] $CleanTemplateSourceRoot = 'E:\EpicVM\clean-template-source',
    [int] $BuilderShutdownTimeoutSeconds = 300,
    [PSCredential] $GuestCredential,
    [PSCredential] $BootstrapCredential,
    [scriptblock] $CommandInvoker = $null,
    [scriptblock] $GuestInvoker = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-EpicVMTemplateError {
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][string]$Message)
    $exception = [System.InvalidOperationException]::new($Message)
    $exception | Add-Member -MemberType NoteProperty -Name ErrorCode -Value $Code -Force
    return $exception
}

function Invoke-EpicVMTemplateCommand {
    param([Parameter(Mandatory)][string]$Name,[hashtable]$Parameters=@{})
    if ($null -ne $script:CommandInvoker) { return & $script:CommandInvoker $Name $Parameters }
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) { throw (New-EpicVMTemplateError -Code 'provider_unavailable' -Message 'The Hyper-V template provider is unavailable.') }
    return & $Name @Parameters
}

function Invoke-EpicVMTemplateGuestScript {
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][scriptblock]$Script,
        [AllowNull()][object[]]$ArgumentList=@()
    )
    if ($null -ne $script:GuestInvoker) { return & $script:GuestInvoker $VmName $Credential $Script $ArgumentList }
    $guestJob=$null
    try {
        $guestJob=Invoke-Command -VMName $VmName -Credential $Credential -ScriptBlock $Script -ArgumentList $ArgumentList -AsJob -ErrorAction Stop
        $completedJob=Wait-Job -Job $guestJob -Timeout 1200
        if($null -eq $completedJob){
            Stop-Job -Job $guestJob -ErrorAction SilentlyContinue
            throw (New-EpicVMTemplateError -Code 'guest_sanitation_timeout' -Message 'Template guest sanitation exceeded 20 minutes.')
        }
        return Receive-Job -Job $guestJob -ErrorAction Stop
    } finally {
        if($null -ne $guestJob){Remove-Job -Job $guestJob -Force -ErrorAction SilentlyContinue}
    }
}

function Test-EpicVMPathUnderRoot {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root)
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@([char]92,[char]47))
        $base = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@([char]92,[char]47))
        return $full.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($base + '\',[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Protect-EpicVMTemplateBootstrapSecret {
    param([Parameter(Mandatory)][PSCredential]$Credential,[Parameter(Mandatory)][string]$Path)
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
        try {
            $protected = [Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        } finally { [Array]::Clear($bytes,0,$bytes.Length) }
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        # The installed blob is deliberately read-only to Administrators. A
        # retry therefore cannot rewrite it in place. Build and ACL a sibling
        # file first, then replace the old blob atomically through the secured
        # parent directory without ever persisting plaintext.
        if(Test-Path -LiteralPath $Path){
            # Migrate blobs produced by the older read-only ACL. No secret is
            # passed to either tool; only the fixed local path is involved.
            & "$env:SystemRoot\System32\takeown.exe" /F $Path /A | Out-Null
            if($LASTEXITCODE -ne 0){throw 'Unable to take ownership of the legacy protected bootstrap blob.'}
            & "$env:SystemRoot\System32\icacls.exe" $Path /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
            if($LASTEXITCODE -ne 0){throw 'Unable to migrate the ACL on the legacy protected bootstrap blob.'}
        }
        $temporaryPath=Join-Path $parent ('.bootstrap-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllBytes($temporaryPath,$protected)
            $acl = Get-Acl -LiteralPath $temporaryPath
            $acl.SetAccessRuleProtection($true,$false)
            @($acl.Access) | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('SYSTEM','FullControl','Allow'))
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('Administrators','FullControl','Allow'))
            Set-Acl -LiteralPath $temporaryPath -AclObject $acl
            Move-Item -LiteralPath $temporaryPath -Destination $Path -Force -ErrorAction Stop
        } finally {
            if(Test-Path -LiteralPath $temporaryPath){Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue}
        }
    } finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        $plain = $null
    }
}

function Get-EpicVMSourceDisk {
    param(
        [Parameter(Mandatory)][string]$ExportPath,
        [Parameter(Mandatory)][string]$SourceLeafName
    )
    # Export-VM preserves the active checkpoint chain. Select the exact leaf
    # attached to the source instead of silently falling back to an older base
    # VHDX, then Convert-VHD will flatten that chain into the independent disk.
    $disks = @(Get-ChildItem -LiteralPath $ExportPath -Recurse -File -ErrorAction Stop | Where-Object {
        $_.Name -ieq $SourceLeafName -and $_.Extension -in @('.vhdx','.avhdx')
    })
    if ($disks.Count -ne 1) { throw (New-EpicVMTemplateError -Code 'source_layout_invalid' -Message 'The exported source must contain exactly one matching active disk leaf.') }
    return $disks[0].FullName
}

function Get-EpicVMTemplateGuestSanitizer {
    return {
        param($BootstrapName,$BootstrapPassword,$BootstrapPath,$ExpectedSunshineVersion,$TimeZoneId)
        $ErrorActionPreference='Stop'
        $secure = ConvertTo-SecureString $BootstrapPassword -AsPlainText -Force
        $existingBootstrap = Get-LocalUser -Name $BootstrapName -ErrorAction SilentlyContinue
        if ($null -eq $existingBootstrap) {
            New-LocalUser -Name $BootstrapName -Password $secure -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword | Out-Null
        } else {
            Set-LocalUser -Name $BootstrapName -Password $secure -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop
        }
        Add-LocalGroupMember -Group 'Administrators' -Member $BootstrapName -ErrorAction SilentlyContinue
        # The bootstrap secret is machine-DPAPI protected inside the builder.
        # It is consumed by the host agent and removed after the first claim.
        $raw=[Text.Encoding]::UTF8.GetBytes([string]$BootstrapPassword)
        try { $sealed=[Security.Cryptography.ProtectedData]::Protect($raw,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine) }
        finally { [Array]::Clear($raw,0,$raw.Length) }
        $bootstrapParent=Split-Path -Parent $BootstrapPath
        if(-not (Test-Path -LiteralPath $bootstrapParent)){New-Item -ItemType Directory -Path $bootstrapParent -Force | Out-Null}
        [IO.File]::WriteAllBytes($BootstrapPath,$sealed)
        $acl=Get-Acl -LiteralPath $BootstrapPath
        $acl.SetAccessRuleProtection($true,$false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('SYSTEM','FullControl','Allow'))
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new('Administrators','Read','Allow'))
        Set-Acl -LiteralPath $BootstrapPath -AclObject $acl

        $sunshineService=Get-Service -Name 'SunshineService' -ErrorAction SilentlyContinue
        if($null -eq $sunshineService){throw 'sunshine_missing'}
        $sunshineCim=Get-CimInstance Win32_Service -Filter "Name='SunshineService'" -ErrorAction SilentlyContinue
        if($null -eq $sunshineCim){throw 'sunshine_missing'}
        $sunshineExe=[string]$sunshineCim.PathName
        if($sunshineExe -match '^"([^"]+)"'){$sunshineExe=$Matches[1]}elseif($sunshineExe -match '^([^ ]+)'){$sunshineExe=$Matches[1]}
        if([string]::IsNullOrWhiteSpace($sunshineExe) -or -not(Test-Path -LiteralPath $sunshineExe -PathType Leaf)){throw 'sunshine_missing'}
        $serviceDirectory=Split-Path -Parent $sunshineExe
        $mainSunshineExe=Join-Path (Split-Path -Parent $serviceDirectory) 'sunshine.exe'
        if(-not (Test-Path -LiteralPath $mainSunshineExe -PathType Leaf)){throw 'sunshine_missing'}
        $installedSunshineVersion=[string]([Diagnostics.FileVersionInfo]::GetVersionInfo($mainSunshineExe).ProductVersion)
        if(-not [string]::IsNullOrWhiteSpace([string]$ExpectedSunshineVersion) -and $installedSunshineVersion -cne [string]$ExpectedSunshineVersion){throw 'sunshine_version_mismatch'}
        if($sunshineService.Status -eq 'Running'){Stop-Service -Name 'SunshineService' -Force -ErrorAction SilentlyContinue}
        Set-Service -Name 'SunshineService' -StartupType Automatic -ErrorAction SilentlyContinue
        @(
            'C:\Program Files\Sunshine\config\sunshine_state.json',
            'C:\ProgramData\Sunshine\config\sunshine_state.json',
            'C:\Users\*\AppData\Local\Sunshine\config\sunshine_state.json',
            'C:\Users\*\AppData\Roaming\Sunshine\config\sunshine_state.json'
        ) | ForEach-Object { Remove-Item -Path $_ -Force -ErrorAction SilentlyContinue }

        Get-NetAdapter -ErrorAction SilentlyContinue | Disable-NetAdapter -Confirm:$false -ErrorAction SilentlyContinue
        $usersToRemove=@(Get-LocalUser | Where-Object { $_.Name -notin @($BootstrapName,'Administrator','DefaultAccount','Guest','WDAGUtilityAccount') })
        # Updated Store packages tied to a soon-to-be-deleted user make
        # Sysprep fail with 0x80073cf2. Remove only those users' registrations
        # on this isolated copy; provisioned apps remain available to clones.
        foreach($localUser in $usersToRemove){
            $userSid=[string]$localUser.SID.Value
            Get-AppxPackage -User $userSid -ErrorAction SilentlyContinue | ForEach-Object {
                Remove-AppxPackage -Package $_.PackageFullName -User $userSid -Confirm:$false -ErrorAction SilentlyContinue
            }
        }
        $usersToRemove | ForEach-Object {
            Remove-LocalUser -Name $_.Name -ErrorAction SilentlyContinue
        }
        Get-CimInstance Win32_UserProfile | Where-Object { -not $_.Special -and $_.LocalPath -notmatch ('\\' + [regex]::Escape($BootstrapName) + '$') } | ForEach-Object {
            Remove-CimInstance -InputObject $_ -ErrorAction SilentlyContinue
        }
        Get-ChildItem 'C:\Users' -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @($BootstrapName,'Public','Default','Default User','All Users') } | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        Remove-Item 'C:\ProgramData\Tailscale','C:\Users\*\AppData\Local\Tailscale','C:\Users\*\AppData\Roaming\Tailscale' -Recurse -Force -ErrorAction SilentlyContinue
        Get-Service -Name Tailscale -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
        @('Application','System','Setup','Security') | ForEach-Object { Clear-WinEvent -LogName $_ -ErrorAction SilentlyContinue }
        Remove-Item 'C:\Windows\Panther\*','C:\Windows\Temp\*','C:\Windows\Logs\*' -Recurse -Force -ErrorAction SilentlyContinue
        # Keep the no-/oobe image contract: PowerShell Direct must be available
        # before the claim, so Windows cannot be left inside interactive OOBE.
        # The bootstrap account intentionally stays for first-boot setup.
        $oobePolicy=New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OOBE' -Force
        Set-ItemProperty -LiteralPath $oobePolicy.PSPath -Name 'DisablePrivacyExperience' -Value 1 -Type DWord
        # Time-sync baseline for clones: w32time always-on and the machine
        # zone pinned to the host zone captured by the builder caller.
        Set-Service -Name 'w32time' -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name 'w32time' -ErrorAction SilentlyContinue
        if(-not [string]::IsNullOrWhiteSpace([string]$TimeZoneId)){
            $safeTimeZone=[string]$TimeZoneId -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;'
            try { tzutil.exe /s ([string]$TimeZoneId) } catch { }
            $unattendXml=@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <ComputerName>*</ComputerName>
      <CopyProfile>false</CopyProfile>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
      <TimeZone>$safeTimeZone</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <HideEULAPage>true</HideEULAPage>
      <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
      <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
      <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
      <ProtectYourPC>3</ProtectYourPC>
    </component>
  </settings>
</unattend>
"@
            $unattendPath=Join-Path $env:SystemRoot 'System32\Sysprep\unattend.xml'
            [IO.File]::WriteAllText($unattendPath,$unattendXml,[Text.UTF8Encoding]::new($false))
            if(-not (Test-Path -LiteralPath $unattendPath -PathType Leaf)){throw 'unattend_write_failed'}
            try {
                $null=[xml][IO.File]::ReadAllText($unattendPath)
            } catch { throw 'unattend_validation_failed' }
            # /generalize resets the zone before a clone can authenticate and
            # the no-/oobe contract does not execute oobeSystem settings.
            # Apply the host zone once at startup under SYSTEM, then self-delete.
            $baselinePath=Join-Path $env:SystemRoot 'System32\EpicVM-TimeBaseline.ps1'
            $baselineScript=@'
$ErrorActionPreference='SilentlyContinue'
tzutil.exe /s '__EPICVM_TIMEZONE__'
Set-Service -Name 'w32time' -StartupType Automatic
Start-Service -Name 'w32time'
Unregister-ScheduledTask -TaskName 'EpicVM-TimeBaseline' -Confirm:$false
Remove-Item -LiteralPath $PSCommandPath -Force
'@.Replace('__EPICVM_TIMEZONE__',[string]$TimeZoneId)
            [IO.File]::WriteAllText($baselinePath,$baselineScript,[Text.UTF8Encoding]::new($false))
            $baselineAction=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$baselinePath`""
            $baselineTrigger=New-ScheduledTaskTrigger -AtStartup
            Register-ScheduledTask -TaskName 'EpicVM-TimeBaseline' -Action $baselineAction -Trigger $baselineTrigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
            if($null -eq (Get-ScheduledTask -TaskName 'EpicVM-TimeBaseline' -ErrorAction SilentlyContinue)){throw 'time_baseline_task_registration_failed'}
        }
        # Keep the sanitized bootstrap account available for the first
        # PowerShell Direct probe. Generalized clones receive a fresh machine
        # identity without entering interactive OOBE before the claim.
        $sysprepProcess=Start-Process -FilePath "$env:SystemRoot\System32\Sysprep\Sysprep.exe" -ArgumentList @('/generalize','/shutdown','/mode:vm','/unattend:C:\Windows\System32\Sysprep\unattend.xml') -Wait -PassThru -WindowStyle Hidden
        $sysprepExitCode=$sysprepProcess.ExitCode
        if($sysprepExitCode -ne 0){
            $sysprepErrorPath=Join-Path $env:SystemRoot 'System32\Sysprep\Panther\setuperr.log'
            $sysprepDetails=if(Test-Path -LiteralPath $sysprepErrorPath){
                ((Get-Content -LiteralPath $sysprepErrorPath -Tail 12 -ErrorAction SilentlyContinue) -join ' ') -replace '[\r\n\x00-\x1f]+',' '
            }else{'setuperr.log was not created'}
            if($sysprepDetails.Length -gt 2048){$sysprepDetails=$sysprepDetails.Substring($sysprepDetails.Length-2048)}
            throw "sysprep_failed exit=$sysprepExitCode details=$sysprepDetails"
        }
        # A few Hyper-V guest builds return success from Sysprep but do not
        # honor /shutdown.  Only after a successful Sysprep exit do we issue
        # this bounded, guest-local shutdown fallback; a failed Sysprep still
        # aborts before any power operation is attempted.
        try {
            Stop-Computer -ComputerName 'localhost' -Force -ErrorAction Stop
        } catch {
            # The shutdown can tear down the remoting channel before the
            # command reports success.  Treat only that expected transport
            # outcome as success; surface any other shutdown error.
            if($_.Exception.Message -notmatch '(?i)(shutdown|shutting down|connection|RPC|remoting)') { throw }
        }
    }
}

function Invoke-EpicVMTemplateBuild {
    param(
        [string]$SourceName=$SourceVmName,
        [string]$OutputRoot=$TemplateRoot,
        [string]$WorkRoot=$WorkingRoot,
        [string]$PrivateSwitch=$PrivateSwitchName,
        [string]$BuilderName=$BuilderVmName,
        [string]$BootstrapName=$BootstrapUser,
        [string]$BootstrapPath=$BootstrapCredentialPath,
        [PSCredential]$SourceCredential=$GuestCredential,
        [PSCredential]$BootstrapSecret=$BootstrapCredential
    )
    if ($UseCleanTemplateSource) {
        if ($SourceName -cne 'EpicVM-CleanTemplateSource' -or [IO.Path]::GetFullPath($CleanTemplateSourceRoot).TrimEnd('\') -ine 'E:\EpicVM\clean-template-source') {
            throw (New-EpicVMTemplateError -Code 'source_name_gate' -Message 'Only the verified EpicVM-CleanTemplateSource fallback may be used.')
        }
    } elseif ($SourceName -cne 'testre') {
        throw (New-EpicVMTemplateError -Code 'source_name_gate' -Message 'Only the verified testre source may be used by this builder.')
    }
    if ($null -eq $SourceCredential -or $null -eq $BootstrapSecret) { throw (New-EpicVMTemplateError -Code 'credential_required' -Message 'Interactive source and bootstrap credentials are required.') }
    $managedRoot=Split-Path -Parent ([IO.Path]::GetFullPath($TemplateRoot).TrimEnd('\'))
    if (-not (Test-EpicVMPathUnderRoot -Path $OutputRoot -Root $TemplateRoot) -or -not (Test-EpicVMPathUnderRoot -Path $WorkRoot -Root $managedRoot)) { throw (New-EpicVMTemplateError -Code 'path_gate' -Message 'Template paths failed the managed-root gate.') }
    $source = @(Invoke-EpicVMTemplateCommand -Name 'Get-VM' -Parameters @{ Name=$SourceName; ErrorAction='Stop' }) | Select-Object -First 1
    if ($null -eq $source -or [string]$source.Name -cne $SourceName) { throw (New-EpicVMTemplateError -Code 'source_not_found' -Message 'The exact source VM was not found.') }
    $sourcePath=[string]$source.Path
    $sourceRoot = if ($UseCleanTemplateSource) { $CleanTemplateSourceRoot } else { $VmRoot }
    if (-not (Test-EpicVMPathUnderRoot -Path $sourcePath -Root $sourceRoot)) { throw (New-EpicVMTemplateError -Code 'source_root_gate' -Message 'The source VM is outside the managed source root.') }
    $expectedNotes = if ($UseCleanTemplateSource) { 'EpicVM-CleanTemplateSource\s*:\s*true' } else { 'EpicVM-Managed\s*:\s*true' }
    if ([string]$source.Notes -notmatch "(?i)$expectedNotes") { throw (New-EpicVMTemplateError -Code 'source_ownership_gate' -Message 'The source VM ownership marker is missing.') }
    $sourceDisks=@(Invoke-EpicVMTemplateCommand -Name 'Get-VMHardDiskDrive' -Parameters @{ VM=$source; ErrorAction='Stop' })
    if($sourceDisks.Count -ne 1){throw (New-EpicVMTemplateError -Code 'source_layout_invalid' -Message 'The source VM must have exactly one attached disk.')}
    $sourceDiskPath=[IO.Path]::GetFullPath([string]$sourceDisks[0].Path)
    if(-not (Test-EpicVMPathUnderRoot -Path $sourceDiskPath -Root $sourceRoot)){throw (New-EpicVMTemplateError -Code 'source_disk_root_gate' -Message 'The source disk is outside the managed source root.')}
    $sourceDiskLeafName=Split-Path -Leaf $sourceDiskPath
    $builderRoot=Join-Path $WorkRoot ("builder-" + [guid]::NewGuid().ToString('N'))
    $exportRoot=Join-Path $builderRoot 'export'
    $builderDisk=Join-Path $builderRoot 'builder.vhdx'
    $stageRoot=Join-Path $OutputRoot (".$TemplateName-" + [guid]::NewGuid().ToString('N'))
    $finalRoot=Join-Path $OutputRoot $TemplateName
    $sourceWasRunning=([string]$source.State -ieq 'Running')
    $sourceStopped=$false; $builderCreated=$false; $sourceRestarted=$false; $restartFailure=$null
    try {
        if (Test-Path -LiteralPath $finalRoot) { throw (New-EpicVMTemplateError -Code 'immutable_exists' -Message 'The immutable template already exists.') }
        New-Item -ItemType Directory -Path $OutputRoot,$exportRoot,$stageRoot -Force | Out-Null
        if ($sourceWasRunning) { Invoke-EpicVMTemplateCommand -Name 'Stop-VM' -Parameters @{ Name=$SourceName; ErrorAction='Stop' } | Out-Null; $sourceStopped=$true }
        Invoke-EpicVMTemplateCommand -Name 'Export-VM' -Parameters @{ Name=$SourceName; Path=$exportRoot; ErrorAction='Stop' } | Out-Null
        $exportedDisk=Get-EpicVMSourceDisk -ExportPath $exportRoot -SourceLeafName $sourceDiskLeafName
        Invoke-EpicVMTemplateCommand -Name 'Convert-VHD' -Parameters @{ Path=$exportedDisk; DestinationPath=$builderDisk; VHDType='Dynamic'; ErrorAction='Stop' } | Out-Null
        $flattenedDisk=Invoke-EpicVMTemplateCommand -Name 'Get-VHD' -Parameters @{ Path=$builderDisk; ErrorAction='Stop' }
        if(-not [string]::IsNullOrWhiteSpace([string]$flattenedDisk.ParentPath)){throw (New-EpicVMTemplateError -Code 'source_flatten_failed' -Message 'The independent builder disk still has a parent after conversion.')}
        # The independent builder disk now exists.  Bring the source back
        # immediately; all sanitation and Sysprep work continues on the copy.
        if($sourceStopped -and $sourceWasRunning){
            Invoke-EpicVMTemplateCommand -Name 'Start-VM' -Parameters @{ Name=$SourceName; ErrorAction='Stop' } | Out-Null
            $sourceRestarted=$true
            $sourceStopped=$false
        }
        $switch=@(Invoke-EpicVMTemplateCommand -Name 'Get-VMSwitch' -Parameters @{ Name=$PrivateSwitch; ErrorAction='SilentlyContinue' }) | Select-Object -First 1
        if ($null -eq $switch) { Invoke-EpicVMTemplateCommand -Name 'New-VMSwitch' -Parameters @{ Name=$PrivateSwitch; SwitchType='Private'; ErrorAction='Stop' } | Out-Null }
        elseif ([string]$switch.SwitchType -ine 'Private') { throw (New-EpicVMTemplateError -Code 'network_isolation_gate' -Message 'The template switch is not Private.') }
        Invoke-EpicVMTemplateCommand -Name 'New-VM' -Parameters @{ Name=$BuilderName; MemoryStartupBytes=8589934592; Generation=2; VHDPath=$builderDisk; Path=$builderRoot; SwitchName=$PrivateSwitch; ErrorAction='Stop' } | Out-Null
        $builderCreated=$true
        Invoke-EpicVMTemplateCommand -Name 'Set-VM' -Parameters @{ Name=$BuilderName; Notes='EpicVM-TemplateBuilder: true'; AutomaticStopAction='ShutDown'; AutomaticCheckpointsEnabled=$false; CheckpointType='Disabled'; ErrorAction='Stop' } | Out-Null
        Invoke-EpicVMTemplateCommand -Name 'Start-VM' -Parameters @{ Name=$BuilderName; ErrorAction='Stop' } | Out-Null
        $sanitizer=Get-EpicVMTemplateGuestSanitizer
        $bootstrapBstr=[IntPtr]::Zero
        $guestSanitationCompleted=$false
        $guestShutdownRequested=$false
        try {
            $bootstrapBstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($BootstrapSecret.Password)
            $bootstrapPlain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bootstrapBstr)
            try {
                Invoke-EpicVMTemplateGuestScript -VmName $BuilderName -Credential $SourceCredential -Script $sanitizer -ArgumentList @($BootstrapName,$bootstrapPlain,$BootstrapPath,$SunshineVersion,$GuestTimeZoneId) | Out-Null
                $guestSanitationCompleted=$true
            }
            catch {
                # Sysprep /shutdown can sever PowerShell Direct before the
                # remoting layer returns.  Accept only that exact transport
                # signature; the bounded VM-Off gate below must still pass.
                if($_.Exception.Message -notmatch '(?i)remote session might have ended') { throw }
                $guestShutdownRequested=$true
            }
        } finally {
            if($bootstrapBstr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bootstrapBstr)}
            $bootstrapPlain=$null
        }
        # The host agent needs the same bootstrap password to open PowerShell
        # Direct into each independent clone. Protect it on the host with
        # machine DPAPI; the value is never placed in the manifest or logs.
        Protect-EpicVMTemplateBootstrapSecret -Credential $BootstrapSecret -Path $BootstrapPath
        # Some guests report successful Sysprep but remain Running even after
        # the guest-local shutdown request.  At this point the sanitizer has
        # completed or the only accepted failure was the expected Sysprep
        # remoting disconnect, so force-stop only this disposable builder copy
        # before the normal Off-state verification gate.
        if($guestSanitationCompleted -or $guestShutdownRequested){
            $builderStateBeforeStop=(Invoke-EpicVMTemplateCommand -Name 'Get-VM' -Parameters @{ Name=$BuilderName; ErrorAction='Stop' }).State
            if([string]$builderStateBeforeStop -ieq 'Running'){
                Invoke-EpicVMTemplateCommand -Name 'Stop-VM' -Parameters @{ Name=$BuilderName; Force=$true; ErrorAction='Stop' } | Out-Null
            }
        }
        $shutdownDeadline=[DateTime]::UtcNow.AddSeconds([Math]::Max(60,$BuilderShutdownTimeoutSeconds))
        while($true) {
            $builderState=(Invoke-EpicVMTemplateCommand -Name 'Get-VM' -Parameters @{ Name=$BuilderName; ErrorAction='Stop' }).State
            if([string]$builderState -ieq 'Off'){break}
            if([DateTime]::UtcNow -gt $shutdownDeadline){throw (New-EpicVMTemplateError -Code 'builder_shutdown_timeout' -Message 'The template builder did not shut down after Sysprep.')}
            Start-Sleep -Milliseconds 250
        }
        Copy-Item -LiteralPath $builderDisk -Destination (Join-Path $stageRoot 'win11-25h2.vhdx') -Force -ErrorAction Stop
        $imagePath=Join-Path $stageRoot 'win11-25h2.vhdx'
        $hash=(Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest=[ordered]@{ templateVersion='1.4.0'; name=$TemplateName; build=('win11-25h2-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd')); windowsBuild='Windows 11 25H2'; sha256=$hash; imagePath=(Join-Path $finalRoot 'win11-25h2.vhdx'); bootstrap='machine-dpapi-encrypted-system-admin'; sunshine='installed'; sunshineVersion=$SunshineVersion; sunshineService='SunshineService'; sunshineCredentials='request-only'; gpu='none'; gpuPartition='none'; diskType='Dynamic'; sourceVm=$SourceName; sysprep='/generalize /shutdown /mode:vm /unattend'; unattend='validated-oobe-file+startup-time-baseline'; timeZone=$GuestTimeZoneId; network='private-switch'; fullCopy=$true; immutable=$true; sanitation='accounts;profiles;browser-data;logs;tailscale-identity;sunshine-credentials;machine-generalize'; createdAt=[DateTime]::UtcNow.ToString('o') }
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stageRoot 'manifest.json') -Encoding UTF8 -NoNewline
        New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
        Move-Item -LiteralPath $stageRoot -Destination $finalRoot -Force
        Set-ItemProperty -LiteralPath (Join-Path $finalRoot 'win11-25h2.vhdx') -Name IsReadOnly -Value $true
        Set-ItemProperty -LiteralPath (Join-Path $finalRoot 'manifest.json') -Name IsReadOnly -Value $true
        return [ordered]@{ ok=$true; templateVersion=$manifest.templateVersion; imagePath=$manifest.imagePath; sha256=$hash }
    } catch { throw }
    finally {
        if ($builderCreated) {
            try { $state=(Invoke-EpicVMTemplateCommand -Name 'Get-VM' -Parameters @{ Name=$BuilderName; ErrorAction='SilentlyContinue' }).State; if ([string]$state -ieq 'Running') { Invoke-EpicVMTemplateCommand -Name 'Stop-VM' -Parameters @{ Name=$BuilderName; Force=$true; ErrorAction='SilentlyContinue' } | Out-Null } } catch { }
            try { Invoke-EpicVMTemplateCommand -Name 'Remove-VM' -Parameters @{ Name=$BuilderName; Force=$true; ErrorAction='SilentlyContinue' } | Out-Null } catch { }
        }
        if (Test-Path -LiteralPath $builderRoot) { try { Remove-Item -LiteralPath $builderRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
        if (Test-Path -LiteralPath $stageRoot) { try { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { } }
        if ($sourceStopped -and $sourceWasRunning) {
            try { Invoke-EpicVMTemplateCommand -Name 'Start-VM' -Parameters @{ Name=$SourceName; ErrorAction='Stop' } | Out-Null; $sourceRestarted=$true }
            catch { $restartFailure=$_.Exception }
            if($null -ne $restartFailure){throw (New-EpicVMTemplateError -Code 'source_restart_failed' -Message 'The source VM could not be restarted after template work.')}
        }
    }
}

if ($Run) {
    Invoke-EpicVMTemplateBuild | ConvertTo-Json -Depth 8
}
