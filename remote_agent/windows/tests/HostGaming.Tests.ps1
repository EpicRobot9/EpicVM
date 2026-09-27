BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'EpicVM.Agent.ps1') -NoStart
}

Describe 'Host gaming owner and seat policy' {
    It 'uses readable, stable names for new seat accounts' {
        Mock Get-LocalUser { $null }
        $a = Get-EpicVMHostGamingAccount 'portal:alice'
        $a | Should -Be 'EpicVM_alice'
        $a | Should -Be (Get-EpicVMHostGamingAccount 'portal:alice')
        $a | Should -Not -Be (Get-EpicVMHostGamingAccount 'portal:bob')
        $a | Should -Not -Be (Get-EpicVMHostGamingAccount 'dashboard-config:alice')
        (Get-EpicVMHostGamingAccount 'portal:a-very-long-user-name').Length | Should -BeLessOrEqual 20
        { Get-EpicVMHostGamingAccount 'portal:alice/../../' } | Should -Throw
    }

    It 'keeps using an existing legacy seat account' {
        Mock Get-LocalUser { [pscustomobject]@{Name=$Name} }
        (Get-EpicVMHostGamingAccount 'portal:alice') | Should -Match '^evseat_[a-f0-9]{13}$'
    }

    It 'does not reach the seat service for an unknown game' {
        Mock Get-EpicVMHostGamingCatalog { @() }
        Mock Invoke-EpicVMMultiSeat { throw 'service should not be called' }
        { Start-EpicVMHostGame @{owner='portal:alice';gameId='unknown'} } | Should -Throw '*not in the host catalog*'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0
    }

    It 'blocks launches when the isolated display driver is absent' {
        Mock Get-EpicVMHostGamingCatalog { @(@{id='harmless';title='Harmless';executable=$PSCommandPath}) }
        Mock Get-Service { [pscustomobject]@{Status='Running'} } -ParameterFilter { $Name -eq 'MultiSeatService' }
        Mock Invoke-EpicVMMultiSeat {
            if ($Path -eq '/api/system/auth') { return @{authEnabled=$true} }
            if ($Path -eq '/api/system/displays') { return @{sudoVdaFound=$false} }
            if ($Path -eq '/api/seats/') { return @() }
            throw 'No mutation expected'
        }
        (Get-EpicVMHostGamingView).ready | Should -BeFalse
        { Start-EpicVMHostGame @{owner='portal:alice';gameId='harmless'} } | Should -Throw '*not ready*'
        Should -Invoke Invoke-EpicVMMultiSeat -ParameterFilter { $Method -ne 'GET' } -Times 0
    }

    It 'registers host gaming mutation routes as serialized operations' {
        Test-EpicVMMutationRequest -Method POST -Path '/v1/host-gaming/launch' | Should -BeTrue
        Test-EpicVMMutationRequest -Method POST -Path '/v1/host-gaming/desktop' | Should -BeTrue
        Test-EpicVMMutationRequest -Method POST -Path '/v1/host-gaming/stop' | Should -BeTrue
        Test-EpicVMMutationRequest -Method POST -Path '/v1/host-gaming/recover' | Should -BeTrue
        Test-EpicVMMutationRequest -Method POST -Path '/v1/host-gaming/games/remove' | Should -BeTrue
    }

    It 'opens a ready desktop seat without launching an application' {
        $account = Get-EpicVMHostGamingAccount 'portal:alice'
        $seatId = '11111111-1111-1111-1111-111111111111'
        Mock Get-EpicVMHostGamingView { @{ready=$true;seats=@(@{id=$seatId;accountName=$account;status='Ready';portBase=48100})} }
        Mock Get-EpicVMApolloAuth { @{username='stream';password='test'} }
        Mock Invoke-EpicVMMultiSeat {
            if ($Method -eq 'GET' -and $Path -eq "/api/seats/$seatId") {
                return @{id=$seatId;accountName=$account;status='Ready';portBase=48100}
            }
            throw 'Desktop must not launch an application'
        }
        $result = Start-EpicVMHostDesktop @{owner='portal:alice'}
        $result.kind | Should -Be 'desktop'
        $result.seatId | Should -Be $seatId
        Should -Invoke Invoke-EpicVMMultiSeat -ParameterFilter { $Method -eq 'POST' } -Times 0
    }

    It 'reveals only an EpicVM managed account credential' {
        $account = Get-EpicVMHostGamingAccount 'portal:alice'
        Mock Invoke-EpicVMMultiSeat {
            if ($Path -eq '/api/accounts/') { return @(@{username=$account;isManaged=$true}) }
            if ($Path -eq "/api/accounts/$account/credential/reveal") { return @{password='test-only-password'} }
            throw 'Unexpected request'
        }
        $result = Reveal-EpicVMHostAccountCredential @{owner='portal:alice'}
        $result.accountName | Should -Be $account
        $result.password | Should -Be 'test-only-password'
    }

    It 'refuses to recover a seat outside the EpicVM account namespace' {
        Mock Get-EpicVMHostGamingView { @{seats=@(@{id='11111111-1111-1111-1111-111111111111';accountName='personal';status='Error'})} }
        Mock Invoke-EpicVMMultiSeat { throw 'service mutation should not be called' }
        { Recover-EpicVMHostGaming @{seatId='11111111-1111-1111-1111-111111111111'} } | Should -Throw '*not managed*'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0
    }
}
