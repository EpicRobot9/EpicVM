#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'providers/HyperVProvider.ps1')
    . (Join-Path $windowsRoot 'providers/GuestProvider.ps1')
}

Describe 'PowerShell Direct guest provider' {
    It 'waits for the new interactive desktop after requesting one guest reboot' {
        Mock Invoke-EpicVMPowerShellDirectOnce { @{ok=$true} }
        $script:desktopPolls=0
        Mock Invoke-EpicVMManagementTransport { $script:desktopPolls++; @{ok=($script:desktopPolls -ge 2)} }
        Mock Start-Sleep {}
        $credential=[PSCredential]::new('operator',(ConvertTo-SecureString 'fixture-password' -AsPlainText -Force))
        Wait-EpicVMGamingDesktopAfterRestart -Provider @{} -VmName alpha -VmId 'fixture-vm' -GuestAddress '100.64.0.2' -Credential $credential -DirectCredential $credential -GuestUser operator -PreviousBoot 'previous-boot' -TimeoutSeconds 3
        Should -Invoke Invoke-EpicVMPowerShellDirectOnce -Times 1 -ParameterFilter {$VmName -eq 'alpha' -and $Script.ToString() -match 'shutdown.exe'}
        Should -Invoke Invoke-EpicVMManagementTransport -Times 2 -ParameterFilter {$ArgumentList[1] -eq 'previous-boot' -and $RetryCount -eq 0}
    }
    It 'requires a changed boot, the expected user, and a desktop process' -ForEach @(
        @{LoggedOn=$true;NewBoot=$true;SessionId=1;Expected=$true},
        @{LoggedOn=$false;NewBoot=$true;SessionId=1;Expected=$false},
        @{LoggedOn=$true;NewBoot=$false;SessionId=1;Expected=$false},
        @{LoggedOn=$true;NewBoot=$true;SessionId=0;Expected=$false}
    ) {
        $script:desktopLoggedOn=$LoggedOn
        $script:desktopNewBoot=$NewBoot
        $script:desktopSessionId=$SessionId
        Mock Get-CimInstance { param($ClassName)
            if($ClassName -eq 'Win32_ComputerSystem') { @{UserName=$(if($script:desktopLoggedOn){$env:COMPUTERNAME+'\operator'}else{''})} }
            else { @{LastBootUpTime=$(if($script:desktopNewBoot){[DateTime]'2026-09-13T20:00:00Z'}else{[DateTime]'2026-09-13T19:00:00Z'})} }
        }
        Mock Get-Process { [pscustomobject]@{SessionId=$script:desktopSessionId} }
        $previous=([DateTime]'2026-09-13T19:00:00Z').ToUniversalTime().ToString('o')
        $result=& (Get-EpicVMGamingDesktopSessionScript) operator $previous
        $result.ok | Should -Be $Expected
    }
    It 'uses the injected boundary and returns only redacted verification fields' {
        $script:invoked = $false
        $provider = [pscustomobject]@{
            Name='Mock'
        PowerShellDirectInvoker={ param($vm,$credential,$scriptBlock,$args) $script:invoked=$true; if($credential.UserName -eq 'EpicVMBootstrap'){ @{ ok=$true; accountConfigured=$true; adminVerified=$true } } elseif($scriptBlock.ToString() -match 'rdp_setup'){ @{ ok=$true; listener=$true; firewallScoped=$true } } else { @{ ok=$true; bootstrapRemoved=$true } } }
            BootstrapCredentialLoader={ param($path,$user) [PSCredential]::new($user,(ConvertTo-SecureString ('x' * 16) -AsPlainText -Force)) }
        }
        $config=[pscustomobject]@{BootstrapCredentialPath='mock.dpapi';BootstrapUser='EpicVMBootstrap'}
        $result=Invoke-EpicVMGuestConfiguration -Provider $provider -Config $config -VmName 'alpha' -DesiredUser 'operator' -DesiredPassword ('y' * 16)
        $script:invoked | Should -BeTrue
        $result.ok | Should -BeTrue
        ($result.Keys -join ',') | Should -Not -Match 'password|secret|token'
    }

    It 'uses an existing-user Set-LocalUser form supported by the guest LocalAccounts module' {
        $text = (Get-EpicVMGuestConfigurationScript).ToString()
        $text | Should -Match 'Set-LocalUser -Name \$DesiredUser -Password \$secure -AccountNeverExpires -ErrorAction Stop'
        $text | Should -Not -Match 'Set-LocalUser -Name \$DesiredUser -Password \$secure -AccountNeverExpires -PasswordNeverExpires'
    }

    It 'ships the scoped NLA and Tailscale-only firewall reconciliation' {
        $account = Get-EpicVMGuestConfigurationScript
        $text = $account.ToString()
        $rdp = Get-EpicVMGuestRdpConfigurationScript
        $rdpText = $rdp.ToString()
        $rdpText | Should -Match 'UserAuthentication'
        $rdpText | Should -Match '100.64.0.0/10'
        $rdpText | Should -Match '100.64.0.0/255.192.0.0'
        $rdpText | Should -Match 'EpicVM-RDP-Tailscale'
        $text | Should -Match 'S-1-5-32-544'
        $text | Should -Match 'Get-LocalGroup -SID'
        $text | Should -Not -Match 'net\.exe localgroup'
        $cleanup = Get-EpicVMGuestBootstrapCleanupScript
        $cleanup.ToString() | Should -Match 'Remove-LocalUser'
        $text | Should -Match 'accountConfigured'
        }

    It 'defers bootstrap removal until readiness and cleanup sessions use the new administrator' {
        $script:credentialUsers = @()
        $provider = [pscustomobject]@{
            PowerShellDirectInvoker={ param($vm,$credential,$scriptBlock,$args) $script:credentialUsers += $credential.UserName; if($credential.UserName -eq 'EpicVMBootstrap'){ @{ ok=$true; accountConfigured=$true; adminVerified=$true } } elseif($scriptBlock.ToString() -match 'rdp_setup'){ @{ ok=$true; listener=$true; firewallScoped=$true } } else { @{ ok=$true; bootstrapRemoved=$true } } }
            BootstrapCredentialLoader={ param($path,$user) [PSCredential]::new($user,(ConvertTo-SecureString ('x' * 16) -AsPlainText -Force)) }
        }
        $config=[pscustomobject]@{BootstrapCredentialPath='mock.dpapi';BootstrapUser='EpicVMBootstrap'}
        $result=Invoke-EpicVMGuestConfiguration -Provider $provider -Config $config -VmName 'alpha' -DesiredUser 'operator' -DesiredPassword ('y' * 16)
        $result.bootstrapRemoved | Should -BeTrue
        $script:credentialUsers | Should -Be @('EpicVMBootstrap','operator','operator','operator')
    }

    It 'waits for a read-only bootstrap probe before guest mutation' {
        $provider = [pscustomobject]@{
            PowerShellDirectInvoker={ param($vm,$credential,$scriptBlock,$args) @{ ok=$true; powershellDirect=$true } }
            BootstrapCredentialLoader={ param($path,$user) [PSCredential]::new($user,(ConvertTo-SecureString ('x' * 16) -AsPlainText -Force)) }
        }
        $config=[pscustomobject]@{BootstrapCredentialPath='mock.dpapi';BootstrapUser='EpicVMBootstrap'}
        (Wait-EpicVMGuestBootstrapReady -Provider $provider -Config $config -VmName 'alpha' -TimeoutSeconds 1 -PollMilliseconds 100) | Should -BeTrue
    }

    It 'classifies the LocalSystem Direct diagnostic without exposing command material' {
        $provider=[pscustomobject]@{
            CommandInvoker={param($command,$parameters)
                switch($command){
                    'Get-VM' { return @{Id='11111111-1111-1111-1111-111111111111';State='Running'} }
                    'Get-VMIntegrationService' { return @(@{Name='Heartbeat';OperationalStatus='OK'},@{Name='PowerShell Direct';Enabled=$true;OperationalStatus='OK'}) }
                    default { throw 'unexpected command' }
                }
            }
            PowerShellDirectInvoker={param($vm,$credential,$scriptBlock,$args) return @{ok=$true;powershellDirect=$true}}
            Available=$true
        }
        $credential=[PSCredential]::new('operator',(ConvertTo-SecureString ('g' * 16) -AsPlainText -Force))
        $result=Invoke-EpicVMPowerShellDirectDiagnostic -Provider $provider -VmName 'alpha' -Credential $credential
        $result.code | Should -Be 'ok'
        $result.sessionCreated | Should -BeTrue
        ($result.PSObject.Properties.Name -join ',') | Should -Not -Match 'password|token|command|path|exception'
    }

    It 'distinguishes disabled Direct service from a channel-open failure' {
        $provider=[pscustomobject]@{
            CommandInvoker={param($command,$parameters)
                switch($command){
                    'Get-VM' { return @{Id='11111111-1111-1111-1111-111111111111';State='Running'} }
                    'Get-VMIntegrationService' { return @(@{Name='Heartbeat';OperationalStatus='OK'},@{Name='PowerShell Direct';Enabled=$false;OperationalStatus='OK'}) }
                    default { throw 'unexpected command' }
                }
            }
            Available=$true
        }
        $credential=[PSCredential]::new('operator',(ConvertTo-SecureString ('g' * 16) -AsPlainText -Force))
        (Invoke-EpicVMPowerShellDirectDiagnostic -Provider $provider -VmName 'alpha' -Credential $credential).code | Should -Be 'direct_service_disabled'
    }

    It 'uses VM-ID session lifecycle with cancellable PowerShell pipelines' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match 'New-PSSession'
        $text | Should -Match 'AddScript\(\$workerScript\.ToString\(\)\)'
        $text | Should -Match 'AddArgument\(\$vmGuid\)'
        $text | Should -Match 'BeginInvoke\(\$workerInput,\$workerOutput\)'
        $text | Should -Match 'Stop\(\)'
        $text | Should -Match 'Remove-PSSession'
        $text | Should -Not -Match '-AsJob'
        $text | Should -Match '\[int\]\$TimeoutSeconds=10'
        $text | Should -Match '\[int\]\$RetryCount=1'
        $text | Should -Match 'if\(@\(\$GuestArguments\)\.Count -gt 0\)'
        $text | Should -Match 'explicit session lifecycle'
    }

    It 'keeps Direct open, execute, collect, and close in one worker runspace' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match '\$workerScript=\{'
        $text | Should -Match 'New-PSSession -VMId'
        $text | Should -Match 'Invoke-Command -Session \$session'
        $text | Should -Match 'Remove-PSSession -Session \$session'
        $text | Should -Not -Match '\$openPipeline=.*New-PSSession'
        $text | Should -Not -Match '\$executePipeline=.*Invoke-Command'
    }

    It 'recognizes dictionary-backed worker phase and result records' {
        $phase = [ordered]@{ epicvmDirectPhase = 'execute'; sessionCreated = $true }
        $result = [ordered]@{ epicvmDirectResult = [ordered]@{ ok = $true; powershellDirect = $true } }
        (Test-EpicVMPowerShellDirectRecordKey -Record $phase -Name 'epicvmDirectPhase') | Should -BeTrue
        (Test-EpicVMPowerShellDirectRecordKey -Record $result -Name 'epicvmDirectResult') | Should -BeTrue
    }

    It 'gives guest writes bounded no-replay windows' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match '\$accountScript.*-TimeoutSeconds 45 -RetryCount 0'
        $text | Should -Match '\$rdpScript.*-TimeoutSeconds 60 -RetryCount 0'
        $text | Should -Match 'Get-EpicVMGuestBootstrapCleanupScript\).*?-TimeoutSeconds 30 -RetryCount 0'
    }

    It 'gives Sunshine writes a longer no-replay window and retries only read-only readiness' {
        $script:managementCalls = @()
        $provider = [pscustomobject]@{
            ManagementInvoker={
            param($address,$credential,$scriptBlock,$args,$timeout,$port,$useSsl)
            $script:managementCalls += [pscustomobject]@{
                timeout = [int]$timeout
                script = [string]$scriptBlock
            }
            if($script:managementCalls.Count -eq 1){
                return @{ok=$true;managementEndpoint=$true}
            }
            if($script:managementCalls.Count -eq 2){
                return @{ok=$true;serviceRunning=$true;listener=$true;firewallScoped=$true}
            }
            return @{ok=$true;serviceRunning=$true;listener=$true}
            }
        }
        $config=[pscustomobject]@{SunshineServiceName='SunshineService';SunshineVersion='2026.516.143833';SunshineStatePaths=@()}
        $result=Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16)
        $result.ok | Should -BeTrue
        $script:managementCalls.Count | Should -Be 3
        $script:managementCalls[0].timeout | Should -Be 30
        $script:managementCalls[0].script | Should -Match 'managementEndpoint'
        $script:managementCalls[1].timeout | Should -Be 75
        $script:managementCalls[1].script | Should -Match '47990'
        $script:managementCalls[2].timeout | Should -Be 60
        $script:managementCalls[2].script | Should -Match '47990'
        $script:managementCalls[1].script | Should -Not -Match 'managementEndpoint'
    }

    It 'keeps the Sunshine executable filter valid in a remoting scriptblock' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match '\(Test-Path -LiteralPath \(\[string\]\$_\) -PathType Leaf\) -and'
        $text | Should -Match '\[IO\.Path\]::GetFileName\(\[string\]\$_\) -ieq ''sunshine\.exe'''
    }

    It 'grants Sunshine write access to its credential state file' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match "SYSTEM','Modify','Allow"
        $text | Should -Match "serviceAccount,'Modify','Allow"
    }

    It 'keeps an injected management boundary authoritative' {
        $script:managementCalls = @()
        $script:directCalls = @()
        $provider = [pscustomobject]@{
            ManagementInvoker={
                param($address,$credential,$scriptBlock,$args,$timeout,$port,$useSsl)
                $script:managementCalls += [pscustomobject]@{timeout=[int]$timeout;script=[string]$scriptBlock}
                if($script:managementCalls.Count -eq 1){throw 'EPICVM_MANAGEMENT_OPEN_FAILED'}
                if($script:managementCalls.Count -eq 2){return @{ok=$true;managementEndpoint=$true}}
                if($script:managementCalls.Count -eq 3){return @{ok=$true;serviceRunning=$true;listener=$true;firewallScoped=$true}}
                return @{ok=$true;serviceRunning=$true;listener=$true}
            }
            PowerShellDirectInvoker={
                param($vm,$credential,$scriptBlock,$args)
                $script:directCalls += [pscustomobject]@{timeout=45;script=[string]$scriptBlock}
                return @{ok=$true;managementEndpoint=$true;firewallScoped=$true}
            }
        }
        $config=[pscustomobject]@{ManagementPort=5985;SunshineServiceName='SunshineService';SunshineVersion='2026.516.143833';SunshineStatePaths=@()}
        $result=Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16)
        $result.ok | Should -BeTrue
        $script:directCalls.Count | Should -Be 0
        $script:managementCalls.Count | Should -Be 4
        $script:managementCalls[0].timeout | Should -Be 30
        $script:managementCalls[1].timeout | Should -Be 30
        $script:managementCalls[2].timeout | Should -Be 75
        $script:managementCalls[3].timeout | Should -Be 60
    }

    It 'reuses a persisted management handoff without falling back to Direct' {
        $script:managementCalls = @()
        $provider = [pscustomobject]@{
            ManagementInvoker={
                param($address,$credential,$scriptBlock,$args,$timeout,$port,$useSsl)
                $script:managementCalls += [pscustomobject]@{timeout=[int]$timeout;script=[string]$scriptBlock}
                throw 'EPICVM_MANAGEMENT_OPEN_FAILED'
            }
            PowerShellDirectInvoker={ throw 'Direct must not be called after management_handoff.' }
        }
        $config=[pscustomobject]@{ManagementPort=5985;SunshineServiceName='SunshineService';SunshineVersion='2026.516.143833';SunshineStatePaths=@()}
        $caught=$null
        try {
            Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16) -ManagementHandoffAlreadyVerified $true
        } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'management_transport_failed'
        $script:managementCalls.Count | Should -Be 1
        $caught.Message | Should -Be 'Automatic Sunshine configuration failed.'
    }

    It 'preserves the failing Sunshine sub-stage when the credential-bearing operation fails' {
        $provider = [pscustomobject]@{
            ManagementInvoker={
                param($address,$credential,$scriptBlock,$args,$timeout,$port,$useSsl)
                throw 'EPICVM_MANAGEMENT_OPERATION_FAILED'
            }
            PowerShellDirectInvoker={ throw 'Direct must not be called after management_handoff.' }
        }
        $config=[pscustomobject]@{ManagementPort=5985;SunshineServiceName='SunshineService';SunshineVersion='2026.516.143833';SunshineStatePaths=@()}
        $caught=$null
        try {
            Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16) -ManagementHandoffAlreadyVerified $true
        } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'management_transport_failed'
        $caught.FailureDetailCode | Should -Be 'SUNSHINE_CONFIG_WRITE'
    }

    It 'qualifies bare local accounts only for the WinRM management copy' {
        $secure = ConvertTo-SecureString ('g' * 16) -AsPlainText -Force
        $raw = [PSCredential]::new('operator', $secure)
        $qualified = New-EpicVMWinRMLocalCredential -Credential $raw
        $raw.UserName | Should -Be 'operator'
        $qualified.UserName | Should -Be '.\operator'
        (New-EpicVMWinRMLocalCredential -Credential ([PSCredential]::new('HOST\operator', $secure))).UserName | Should -Be 'HOST\operator'
        (New-EpicVMWinRMLocalCredential -Credential ([PSCredential]::new('operator@example.test', $secure))).UserName | Should -Be 'operator@example.test'
    }

    It 'uses the explicitly local-qualified identity for WinRM Sunshine setup' {
        $script:managementUsers = @()
        $provider = [pscustomobject]@{
            ManagementInvoker={
                param($address,$credential,$scriptBlock,$args,$timeout,$port,$useSsl)
                $script:managementUsers += $credential.UserName
                if($script:managementUsers.Count -eq 1){ return @{ok=$true;managementEndpoint=$true} }
                if($script:managementUsers.Count -eq 2){ return @{ok=$true;serviceRunning=$true;listener=$true;firewallScoped=$true} }
                return @{ok=$true;serviceRunning=$true;listener=$true}
            }
        }
        $config=[pscustomobject]@{SunshineServiceName='SunshineService';SunshineVersion='2026.516.143833';SunshineStatePaths=@()}
        $result=Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16)
        $result.ok | Should -BeTrue
        $script:managementUsers | Should -Be @('.\operator','.\operator','.\operator')
    }

    It 'does not use PowerShell Direct for Sunshine writes' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match 'Sunshine never runs through Direct'
        $text | Should -Match 'Invoke-EpicVMPowerShellDirectDiagnostic'
        $text | Should -Not -Match 'Invoke-EpicVMPowerShellDirectOnce -Provider \$Provider -VmName \$VmName -Credential \$credential -Script \$sunshineScript'
    }

    It 'fails the independent Tailscale gate before any streaming write' {
        $provider = [pscustomobject]@{
            PowerShellDirectInvoker = { throw 'EPICVM_POWERSHELL_DIRECT_OPERATION_FAILED' }
        }
        $config=[pscustomobject]@{ManagementPort=5985;SunshineServiceName='SunshineService';SunshineVersion='2026.516.143833';SunshineStatePaths=@()}
        $caught=$null
        try {
            Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16)
        } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'tailscale_unreachable'
    }

    It 'keeps the native management repair below the dashboard proxy budget' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match 'Test-EpicVMManagementPort'
        $text | Should -Match 'TimeoutMilliseconds=2000'
        $text | Should -Match '\$managementInitialTimeout=if\(\$null -eq \$managementInvoker\)\{20\}'
        $text | Should -Match '\$managementRecoveryTimeout=if\(\$null -eq \$managementInvoker\)\{20\}'
        $text | Should -Match 'Set-EpicVMManagementTrustedHost'
        $tailText = Get-Content (Join-Path $windowsRoot 'providers/TailscaleProvider.ps1') -Raw
        $tailText | Should -Match 'AllowUnencrypted.*false'
    }

    It 'keeps WinRM TrustedHosts narrow when the PowerShell 7 WSMan drive is absent' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match 'CurrentVersion\\WSMAN\\Client'
        $text | Should -Match 'EPICVM_MANAGEMENT_TRUSTED_HOSTS_BROAD'
        $text | Should -Not -Match "TrustedHosts.*\*"
    }

    It 'does not retry a credential-bearing PowerShell Direct operation when retry count is zero' {
        $script:callCount = 0
        $provider = [pscustomobject]@{
            PowerShellDirectInvoker={ param($vm,$credential,$scriptBlock,$args) $script:callCount++; throw 'PowerShell Direct probe timed out.' }
        }
        $credential=[PSCredential]::new('operator',(ConvertTo-SecureString ('g' * 16) -AsPlainText -Force))
        $caught=$null
        try { Invoke-EpicVMPowerShellDirect -Provider $provider -VmName 'alpha' -Credential $credential -Script { $true } -TimeoutSeconds 75 -RetryCount 0 } catch { $caught=$_.Exception }
        $script:callCount | Should -Be 1
        $caught | Should -Not -BeNullOrEmpty
    }

    It 'classifies PowerShell Direct failures without exposing transport text' {
        $provider = [pscustomobject]@{
            PowerShellDirectInvoker={ throw 'PowerShell Direct channel unavailable.' }
            BootstrapCredentialLoader={ param($path,$user) [PSCredential]::new($user,(ConvertTo-SecureString ('x' * 16) -AsPlainText -Force)) }
        }
        $config=[pscustomobject]@{BootstrapCredentialPath='mock.dpapi';BootstrapUser='EpicVMBootstrap'}
        $caught=$null
        try { Invoke-EpicVMGuestConfiguration -Provider $provider -Config $config -VmName 'alpha' -DesiredUser 'operator' -DesiredPassword ('y' * 16) } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'direct_transport_error'
        $caught.Message | Should -Be 'The guest configuration gate failed.'
    }

    It 'does not infer a guest credential rejection from generic access denial' {
        $accessDenied = [System.InvalidOperationException]::new('Access is denied.')
        (Get-EpicVMPowerShellDirectFailureCode -ErrorRecord $accessDenied -Phase 'open' -SessionCreated $false) | Should -Be 'direct_transport_error'
        $explicitLogon = [System.InvalidOperationException]::new('The user name or password is incorrect.')
        (Get-EpicVMPowerShellDirectFailureCode -ErrorRecord $explicitLogon -Phase 'open' -SessionCreated $false) | Should -Be 'guest_credentials_rejected'
    }

    It 'best-effort starts the trigger-start Direct service without requiring it to stay idle-running' {
        $script:serviceReads = 0
        Mock -CommandName Get-Service -MockWith {
            $script:serviceReads++
            if($script:serviceReads -eq 1){ return [pscustomobject]@{Status='Stopped';StartType='Manual'} }
            return [pscustomobject]@{Status='Running';StartType='Manual'}
        }
        Mock -CommandName Start-Service -MockWith { }
        $result=Ensure-EpicVMPowerShellDirectHostService
        $result.startAttempted | Should -BeTrue
        $result.startFailed | Should -BeFalse
        $result.after | Should -Be 'Running'
        Should -Invoke Start-Service -Times 1 -Exactly
    }

    It 'keeps Direct service readiness separate from credential markers' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match 'Ensure-EpicVMPowerShellDirectHostService'
        $text | Should -Match "Start-Service -Name 'vmicvmsession'"
        $text | Should -Not -Match 'directText -match[^\r\n]*access is denied'
    }

    It 'classifies bootstrap credential failures safely' {
        $provider = [pscustomobject]@{
            BootstrapCredentialLoader={ throw 'DPAPI bootstrap secret unavailable.' }
        }
        $config=[pscustomobject]@{BootstrapCredentialPath='mock.dpapi';BootstrapUser='EpicVMBootstrap'}
        $caught=$null
        try { Invoke-EpicVMGuestConfiguration -Provider $provider -Config $config -VmName 'alpha' -DesiredUser 'operator' -DesiredPassword ('y' * 16) } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'bootstrap_credential_unavailable'
        $caught.Message | Should -Be 'The machine bootstrap credential could not open the guest channel.'
    }

    It 'propagates only the allowlisted account detail for a partial account failure' {
        $provider = [pscustomobject]@{
            PowerShellDirectInvoker={ param($vm,$credential,$scriptBlock,$args) throw 'guest_account_failed|admin_membership_failed' }
            BootstrapCredentialLoader={ param($path,$user) [PSCredential]::new($user,(ConvertTo-SecureString ('x' * 16) -AsPlainText -Force)) }
        }
        $config=[pscustomobject]@{BootstrapCredentialPath='mock.dpapi';BootstrapUser='EpicVMBootstrap'}
        $caught=$null
        try { Invoke-EpicVMGuestConfiguration -Provider $provider -Config $config -VmName 'alpha' -DesiredUser 'operator' -DesiredPassword ('y' * 16) } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'guest_account_failed'
        $caught.FailureDetailCode | Should -Be 'admin_membership_failed'
        $caught.Message | Should -Be 'The guest configuration gate failed.'
        $caught.Message | Should -Not -Match 'operator|y{4}|password|secret'
    }

    It 'does not attempt RDP after account setup fails' {
        $script:callCount=0
        $script:rdpAttempted=$false
        $provider = [pscustomobject]@{
            PowerShellDirectInvoker={ param($vm,$credential,$scriptBlock,$args) $script:callCount++; if($scriptBlock.ToString() -match 'rdp_setup'){$script:rdpAttempted=$true}; throw 'guest_account_failed|account_create_failed' }
            BootstrapCredentialLoader={ param($path,$user) [PSCredential]::new($user,(ConvertTo-SecureString ('x' * 16) -AsPlainText -Force)) }
        }
        $config=[pscustomobject]@{BootstrapCredentialPath='mock.dpapi';BootstrapUser='EpicVMBootstrap'}
        try { Invoke-EpicVMGuestConfiguration -Provider $provider -Config $config -VmName 'alpha' -DesiredUser 'operator' -DesiredPassword ('y' * 16) } catch { }
        $script:callCount | Should -Be 1
        $script:rdpAttempted | Should -BeFalse
    }

    It 'keeps account creation, update, policy, and SID membership classifications explicit' {
        $text = (Get-EpicVMGuestConfigurationScript).ToString()
        $text | Should -Match 'New-LocalUser'
        $text | Should -Match 'Set-LocalUser'
        $text | Should -Match 'account_create_failed'
        $text | Should -Match 'account_update_failed'
        $text | Should -Match 'account_password_policy_failed'
        $text | Should -Match 'admin_membership_failed'
        $text | Should -Match 'account_verification_failed'
        $text | Should -Match '\.SID'
    }

    It 'returns only an allowlisted Sunshine failure code' {
        $provider = [pscustomobject]@{
            ManagementInvoker={ param($address,$credential,$scriptBlock,$args,$timeout,$port,$useSsl) throw 'EPICVM_SUNSHINE_VERSION_MISMATCH' }
        }
        $config=[pscustomobject]@{
            SunshineServiceName='SunshineService'
            SunshineVersion='2026.516.143833'
            SunshineStatePaths=@('C:\Program Files\Sunshine\config\sunshine_state.json')
        }
        $caught=$null
        try {
            Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16)
        } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'sunshine_version_mismatch'
        $caught.Message | Should -Be 'Automatic Sunshine configuration failed.'
        $caught.Message | Should -Not -Match 'EPICVM|operator|sun-user|password|secret'
    }

    It 'classifies a failed PowerShell Direct transport separately from Sunshine state failures' {
        $provider = [pscustomobject]@{
            ManagementInvoker={ param($address,$credential,$scriptBlock,$args,$timeout,$port,$useSsl) throw 'PowerShell Direct channel unavailable.' }
        }
        $config=[pscustomobject]@{SunshineServiceName='SunshineService';SunshineVersion='2026.516.143833';SunshineStatePaths=@()}
        $caught=$null
        try {
            Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16)
        } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'powershell_direct_failed'
        $caught.Message | Should -Be 'Automatic Sunshine configuration failed.'
    }

    It 'classifies an explicit guest logon rejection without exposing transport text' {
        $provider = [pscustomobject]@{
            ManagementInvoker={ param($address,$credential,$scriptBlock,$args,$timeout,$port,$useSsl) throw 'The user name or password is incorrect.' }
        }
        $config=[pscustomobject]@{SunshineServiceName='SunshineService';SunshineVersion='2026.516.143833';SunshineStatePaths=@()}
        $caught=$null
        try {
            Invoke-EpicVMSunshineConfiguration -Provider $provider -Config $config -VmName 'alpha' -GuestAddress '100.111.82.1' -GuestUsername 'operator' -GuestPassword ('g' * 16) -SunshineUsername 'sun-user' -SunshinePassword ('s' * 16)
        } catch { $caught=$_.Exception }
        $caught.ErrorCode | Should -Be 'guest_credential_rejected'
        $caught.Message | Should -Be 'Automatic Sunshine configuration failed.'
        $caught.Message | Should -Not -Match 'operator|sun-user|incorrect|password'
    }

    It 'derives the installed Sunshine config state path and pins service startup' {
        $text=(Get-EpicVMSunshineConfigurationScript).ToString()
        $text | Should -Match 'derivedState'
        $text | Should -Match 'credentials_file|file_state'
        $text | Should -Match 'Set-Service -Name \$ServiceName -StartupType Automatic'
        $text | Should -Match 'EPICVM_SUNSHINE_STATE_WRITE_FAILED'
    }

    It 'writes the Sunshine password hash with uppercase hexadecimal encoding' {
        $text=(Get-EpicVMSunshineConfigurationScript).ToString()
        $text | Should -Match 'ToUpperInvariant'
        $text | Should -Not -Match 'passwordHash=.*ToLowerInvariant'
    }

    It 'matches Sunshine default hexadecimal byte order for the password hash' {
        $text=(Get-EpicVMSunshineConfigurationScript).ToString()
        $text | Should -Match '\[Array\]::Reverse\(\$digest\)'
    }

    It 'accepts both direct and helper Sunshine service executable layouts' {
        $text=(Get-EpicVMSunshineConfigurationScript).ToString()
        $text | Should -Match '\$servicePath'
        $text | Should -Match 'GetFileName'
        $text | Should -Match 'tools\\sunshine\.exe|sunshine\.exe'
    }

    It 'preserves allowlisted guest markers from a failed remoting child stream' {
        $child=[pscustomobject]@{
            JobStateInfo=[pscustomobject]@{Reason=$null}
            Error=@([System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new('EPICVM_SUNSHINE_LISTENER_FAILED'),
                'safe-marker',
                [System.Management.Automation.ErrorCategory]::InvalidOperation,
                $null))
            Streams=[pscustomobject]@{Error=@()}
        }
        $job=[pscustomobject]@{ChildJobs=@($child)}
        $records=Get-EpicVMPowerShellDirectJobRecords -Job $job
        Get-EpicVMPowerShellDirectSafeMarker -Records $records | Should -Be 'EPICVM_SUNSHINE_LISTENER_FAILED'
    }

    It 'preserves allowlisted Sunshine markers through the nested WinRM wrapper' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match '\$safeGuestMarkers'
        $text | Should -Match 'EPICVM_SUNSHINE_STATE_WRITE_FAILED'
        $text | Should -Match 'SafeMarkers'
        $text | Should -Match 'if\(\$null -ne \$guestMarker\).*safeMarker'
    }

    It 'returns a structured nested WinRM guest failure before outer pipeline cleanup' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match 'ErrorVariable nestedErrors'
        $text | Should -Match 'safeMarker'
        $text | Should -Match 'transportOpened=\$true'
        $text | Should -Match 'failureDetailCode=\$sunshineStage'
    }

    It 'preserves allowlisted account markers emitted by the Direct worker runspace' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match 'epicvmDirectGuestFailure'
        $text | Should -Match 'account_password_policy_failed'
        $text | Should -Match 'guestFailureEnvelope'
        $text | Should -Match 'The guest account operation failed'
    }

    It 'collects nested WinRM output and bounds asynchronous stop during transport cleanup' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match '\$transportInput'
        $text | Should -Match '\$transportOutput'
        $text | Should -Match 'BeginInvoke\(\$transportInput,\$transportOutput\)'
        $text | Should -Match 'BeginStop\('
        $text | Should -Match 'EndStop\('
        $text | Should -Match '\$transportOutput'
    }

    It 'does not synchronously dispose an incomplete timed-out management pipeline' {
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match '\$disposePipeline=\$true'
        $text | Should -Match '\$disposePipeline=\$false'
        $text | Should -Match 'if\(\$disposePipeline -and \$null -ne \$pipeline\)'
    }

    It 'stages gaming capture artifacts in envelope-safe chunks, not one remoting argument' {
        # Regression: shipping ~3 MB of base64 through a single WinRM argument
        # exceeds the guest's default WSMan MaxEnvelopeSizekb and fails the
        # streaming stage opaquely. The payload must be chunk-staged first.
        $text = Get-Content (Join-Path $windowsRoot 'providers/GuestProvider.ps1') -Raw
        $text | Should -Match 'Get-EpicVMGamingCaptureStageScript'
        $text | Should -Match '\$chunkSize=200000'
        $text | Should -Not -Match '\$VddZipBase64'
        $guestStage = (Get-EpicVMGamingCaptureStageScript).ToString()
        # The guest staging script must reassemble atomically and verify length.
        $guestStage | Should -Match 'part-\{0\}\.b64'
        $guestStage | Should -Match 'Move-Item -LiteralPath \$tmp -Destination \$final -Force'
        $guestStage | Should -Match 'EPICVM_CAPTURE_STAGING_FAILED'
        $guestStage | Should -Match '\$combined\.Length -ne \[int\]\$TotalBase64Length'
    }

}
