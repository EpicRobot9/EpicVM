#Requires -Version 7.0
#Requires -Modules Pester

BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'providers/HyperVProvider.ps1')
    . (Join-Path $windowsRoot 'providers/GuestProvider.ps1')
    . (Join-Path $windowsRoot 'providers/TailscaleProvider.ps1')
}

Describe 'Tailscale OAuth enrollment' {
    It 'polls task State separately from runtime result and has one launch path' {
        $text=(Get-EpicVMTailscaleGuestScript).ToString()
        $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$null,[ref]$null)
        $taskFunction=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-EpicVMTailscaleTask'},$true)
        . ([scriptblock]::Create($taskFunction.Extent.Text))
        Mock New-ScheduledTaskAction { [Microsoft.Management.Infrastructure.CimInstance]::new('MSFT_TaskAction','root/Microsoft/Windows/TaskScheduler') }
        Mock New-ScheduledTaskPrincipal { [Microsoft.Management.Infrastructure.CimInstance]::new('MSFT_TaskPrincipal','root/Microsoft/Windows/TaskScheduler') }
        Mock Register-ScheduledTask {}
        Mock Start-ScheduledTask {}
        Mock Unregister-ScheduledTask {}
        Mock Start-Sleep {}
        $script:taskPoll=0
        Mock Get-ScheduledTaskInfo { $script:taskPoll++; [pscustomobject]@{LastTaskResult=$(if($script:taskPoll -eq 1){267011}else{0})} }
        Mock Get-ScheduledTask { [pscustomobject]@{State='Ready'} }
        $result=Invoke-EpicVMTailscaleTask -TaskName test -Execute 'test.exe' -Arguments test -UserId 'machine\operator'
        $result.exitCode | Should -Be 0
        Should -Invoke Get-ScheduledTaskInfo -Times 2
        Should -Invoke Start-ScheduledTask -Times 1
        Should -Invoke New-ScheduledTaskPrincipal -ParameterFilter {$UserId -eq 'machine\operator' -and $LogonType -eq 'S4U' -and $RunLevel -eq 'Highest'} -Times 1
        Should -Invoke Register-ScheduledTask -ParameterFilter { -not $Trigger } -Times 1
    }
    It 'creates a non-reusable preauthorized guest key and verifies the guest IP' {
        $secretPath = 'mock://oauth-secret'
        $script:request = $null
        $provider=[pscustomobject]@{
            TailscaleOAuthClientId='client-id'
            TailscaleOAuthSecretPath=$secretPath
            TailscaleTailnet='example.ts.net'
            TailscaleGuestTag='tag:epicvm-guest'
            TailscaleApiBaseUrl='https://example.invalid/api/v2'
            TailscaleOAuthInvoker={ param($body) @{ access_token='access' } }
            TailscaleOAuthSecretLoader={ param($path) [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
            TailscaleHttpInvoker={ param($method,$url,$headers,$body) if($null -ne $body){$script:request=$body}; if($method -eq 'GET'){ @{ devices=@(@{ id='device-1'; hostname='alpha'; addresses=@('100.111.82.44') }) } } else { @{ key='one-use-key' } } }
            PowerShellDirectInvoker={ param($vm,$credential,$scriptBlock,$args) @{ ok=$true; ip='100.111.82.44' } }
            KnownTailscaleIps=@()
        }
        $result=Invoke-EpicVMTailscaleEnrollment -Provider $provider -Config ([pscustomobject]@{TailscaleExecutable='tailscale.exe'}) -VmName 'alpha' -Username 'operator' -Password ('q' * 16)
        $result.ok | Should -BeTrue
        $result.ip | Should -Be '100.111.82.44'
        $script:request.capabilities.devices.create.reusable | Should -BeFalse
        $script:request.capabilities.devices.create.preauthorized | Should -BeTrue
        $script:request.capabilities.devices.create.tags | Should -Contain 'tag:epicvm-guest'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Match 'NamedPipeServerStream'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Match 'Register-ScheduledTask'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Match "-UserId 'SYSTEM'"
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Match 'New-ScheduledTaskPrincipal'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Match 'file:\\\\.\\pipe\\'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Match '--auth-key'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Not -Match '--authkey'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Match '--unattended=true'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Match 'Restart-Service -Name .Tailscale.'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Not -Match 'ArgumentList\.Add'
        (Get-EpicVMTailscaleGuestScript).ToString() | Should -Not -Match '--authkey\s+\$AuthKey'
    }

    It 'provides a read-only guest address probe for retained network recovery' {
        $scriptText=(Get-EpicVMTailscaleGuestAddressScript).ToString()
        $scriptText | Should -Match 'status --json'
        $scriptText | Should -Match 'BackendState'
        $scriptText | Should -Match 'Self.Online'
        $scriptText | Should -Match 'Get-NetIPAddress'
        $scriptText | Should -Match 'AddressFamily IPv4'
        $scriptText | Should -Match '100'
        $scriptText | Should -Not -Match 'tailscale up|Register-ScheduledTask|Restart-Service'
    }

    It 'rejects a duplicate guest address' {
        $provider=[pscustomobject]@{
            TailscaleOAuthClientId='client-id';TailscaleOAuthSecretPath='mock://oauth-secret';TailscaleTailnet='example.ts.net';TailscaleGuestTag='tag:epicvm-guest'
            TailscaleOAuthSecretLoader={ [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
            TailscaleOAuthInvoker={ @{access_token='access'} }
            TailscaleHttpInvoker={ param($method,$url,$headers,$body) @{key='one-use-key'} }
            PowerShellDirectInvoker={ @{ok=$true;ip='100.111.82.44'} }
            KnownTailscaleIps=@('100.111.82.44')
        }
        { Invoke-EpicVMTailscaleEnrollment -Provider $provider -Config ([pscustomobject]@{TailscaleExecutable='tailscale.exe'}) -VmName 'alpha' -Username 'operator' -Password ('q' * 16) } | Should -Throw '*enrollment*'
    }

    It 'revokes only the recorded Tailscale device identifier' {
        $script:revocation=$null
        $provider=[pscustomobject]@{
            TailscaleOAuthClientId='client-id';TailscaleOAuthSecretPath='mock://oauth-secret'
            TailscaleOAuthSecretLoader={ [PSCredential]::new('oauth-secret',(ConvertTo-SecureString ('z' * 24) -AsPlainText -Force)) }
            TailscaleOAuthInvoker={ @{access_token='access'} }
            TailscaleHttpInvoker={ param($method,$url,$headers,$body) $script:revocation=@{method=$method;url=$url}; @{} }
        }
        $result=Revoke-EpicVMTailscaleDevice -Provider $provider -DeviceId 'device-123'
        $result.revoked | Should -BeTrue
        $script:revocation.method | Should -Be 'DELETE'
        $script:revocation.url | Should -Match '/device/device-123$'
    }
}
