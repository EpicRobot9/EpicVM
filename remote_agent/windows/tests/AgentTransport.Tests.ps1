BeforeAll {
    $windowsRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $windowsRoot 'EpicVM.Agent.ps1') -NoStart
    . (Join-Path $windowsRoot 'AgentTransport.ps1')
    function New-TransportFixture {
        $config = Get-EpicVMDefaultConfig
        $config.Provider = 'Mock'
        $config.ProvisioningStatePath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.json')
        $provider = [pscustomobject]@{
            Name='Mock'; GetVMs={ @() }
            StartVM={ param($name) Start-Sleep -Seconds 2; @{name=$name;state='Running'} }
        }
        New-EpicVMAgentState -Config $config -Token 'fixture-token' -Provider $provider
    }
}
Describe 'Asynchronous agent provisioning' {
    It 'persists a retryable failure if the worker cannot initialize' {
        $state=New-TransportFixture
        $job=New-EpicVMProvisioningJobObject -Id 'worker-failed' -Name 'worker-failed' -Profile standard
        $state.Provisioning.Jobs[$job.id]=$job
        $operation=Start-EpicVMAgentOperation -State $state -AgentPath (Join-Path $TestDrive 'missing-agent.ps1') -JobId $job.id
        try {
            { $operation.Pipeline.EndInvoke($operation.Handle) } | Should -Throw
            Set-EpicVMAgentOperationFailed -State $state -JobId $job.id
            $job.state | Should -Be 'setup_failed:preclaim'
            $job.errorCode | Should -Be 'agent_worker_failed'
            $persisted=New-EpicVMProvisioningStore -Config $state.Config
            $persisted.Jobs[$job.id].state | Should -Be 'setup_failed:preclaim'
            Test-EpicVMProvisioningJobRetryable -Job $job | Should -BeTrue
        }finally{$operation.Pipeline.Dispose()}
    }
    It 'releases a queued reservation after a service restart' {
        $state=New-TransportFixture
        $job=New-EpicVMProvisioningJobObject -Id 'queued-restart' -Name 'queued-restart' -Profile gaming
        $state.Provisioning.Jobs[$job.id]=$job
        Invoke-EpicVMProvisioningRecovery -State $state
        $job.state | Should -Be 'setup_failed:preclaim'
        Test-EpicVMProvisioningJobRetryable -Job $job | Should -BeTrue
    }
    It 'acknowledges a queued job without hashing or cloning in the request' {
        $state = New-TransportFixture
        $state.DeferProvisioning = $true
        Mock Start-EpicVMProvisioningJob { throw 'Clone must run outside the HTTP request.' }
        $response = Invoke-EpicVMApiRequest -State $state -Method POST -Path '/v1/provisioning-jobs' -Headers @{Authorization='Bearer fixture-token'} -Body '{"name":"async-test","profile":"standard"}'
        $response.StatusCode | Should -Be 202
        $response.Body.job.state | Should -Be 'queued'
        $response.Json | Should -Not -Match 'claimToken|claimHash'
        Should -Invoke Start-EpicVMProvisioningJob -Times 0
    }
    It 'runs a mutation in an isolated runspace while reads remain responsive' {
        $state = New-TransportFixture
        $operation = Start-EpicVMAgentOperation -State $state -AgentPath (Join-Path $windowsRoot 'EpicVM.Agent.ps1') -Method POST -Path '/v1/vms/alpha/start' -Headers @{Authorization='Bearer fixture-token'}
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            $health = Invoke-EpicVMApiRequest -State $state -Method GET -Path '/v1/health' -Headers @{Authorization='Bearer fixture-token'}
            $health.StatusCode | Should -Be 200
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 1
            $operation.Handle.IsCompleted | Should -BeFalse
            $result = @($operation.Pipeline.EndInvoke($operation.Handle))
            $result[-1].StatusCode | Should -Be 200
            $result[-1].Body.vm.state | Should -Be 'Running'
        }
        finally { $operation.Pipeline.Dispose() }
    }
    It 'ignores a newer failed job for a previous VM with the same name' {
        $state = New-TransportFixture
        $current = New-EpicVMProvisioningJobObject -Id 'current' -Name 'alpha' -Profile gaming -State streaming_setup
        $current.vmId = 'current-vm'
        $current.updatedAt = '2026-09-12T00:00:00Z'
        $old = New-EpicVMProvisioningJobObject -Id 'old' -Name 'alpha' -Profile gaming -State 'setup_failed:preclaim'
        $old.vmId = 'old-vm'
        $old.updatedAt = '2026-09-13T00:00:00Z'
        $state.Provisioning.Jobs['current'] = $current
        $state.Provisioning.Jobs['old'] = $old
        $inventory = @(Add-EpicVMProvisioningInventoryState -State $state -Vms @(@{name='alpha';id='current-vm'}))
        $inventory[0].provisioningState | Should -Be 'streaming_setup'
    }
}
