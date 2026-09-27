BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
    $script:Tools = @(
        'scripts\Repair-EpicVMActiveManifest.ps1',
        'scripts\Repair-EpicVMSplitState.ps1',
        'scripts\Repair-EpicVMStaleProvisioningState.ps1',
        'scripts\Restore-EpicVMV12Active.ps1'
    )
}

Describe 'EpicVM recovery utilities' {
    It 'all parse under PowerShell 7' {
        foreach ($relative in $script:Tools) {
            $tokens = $null; $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $script:RepoRoot $relative), [ref]$tokens, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        }
    }

    It 'is plan-only by default and under WhatIf' {
        $root = Join-Path $TestDrive 'managed'
        $template = Join-Path $root 'templates\win11-25h2'
        New-Item -ItemType Directory -Path $template -Force | Out-Null
        $image = Join-Path $template 'win11-25h2.vhdx'
        [IO.File]::WriteAllBytes($image, [byte[]](1..32))
        $hash = (Get-FileHash $image -Algorithm SHA256).Hash
        $manifest = [ordered]@{ templateVersion = '1.4.0'; imagePath = 'wrong.vhdx'; sha256 = $hash }
        $manifestPath = Join-Path $template 'manifest.json'
        $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding utf8
        $configPath = Join-Path $root 'config.json'
        [ordered]@{ ManagedRoot = $root; TemplateManifestPath = $manifestPath } |
            ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding utf8
        $reportPath = Join-Path $TestDrive 'plan.json'

        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMActiveManifest.ps1') `
            -ConfigPath $configPath -ReportPath $reportPath | Out-Null
        (Get-Content $manifestPath -Raw) | Should -Match 'wrong.vhdx'
        (Get-Content $reportPath -Raw | ConvertFrom-Json).status | Should -Be 'planned'

        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMActiveManifest.ps1') `
            -ConfigPath $configPath -ReportPath $reportPath -Execute -WhatIf -Confirm:$false | Out-Null
        (Get-Content $manifestPath -Raw) | Should -Match 'wrong.vhdx'
        (Get-Content $reportPath -Raw | ConvertFrom-Json).status | Should -Be 'whatif'
    }

    It 'rejects a manifest outside the configured managed root' {
        $root = Join-Path $TestDrive 'managed'
        $outside = Join-Path $TestDrive 'outside\manifest.json'
        New-Item -ItemType Directory -Path (Split-Path $outside) -Force | Out-Null
        [ordered]@{ ManagedRoot = $root; TemplateManifestPath = $outside } |
            ConvertTo-Json | Set-Content (Join-Path $TestDrive 'config.json') -Encoding utf8
        $report = Join-Path $TestDrive 'rejected.json'
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMActiveManifest.ps1') `
            -ConfigPath (Join-Path $TestDrive 'config.json') -ReportPath $report | Out-Null
        (Get-Content $report -Raw | ConvertFrom-Json).error | Should -Be 'path_outside_managed_root'
    }

    It 'rejects reparse points and unexpected template contents' {
        $root = Join-Path $TestDrive 'managed'; $template = Join-Path $root 'templates\win11-25h2'
        New-Item -ItemType Directory -Path $template -Force | Out-Null
        $image = Join-Path $template 'win11-25h2.vhdx'; [IO.File]::WriteAllBytes($image, [byte[]](1..8))
        $hash = (Get-FileHash $image).Hash; $manifestPath = Join-Path $template 'manifest.json'
        [ordered]@{ imagePath=$image; sha256=$hash } | ConvertTo-Json | Set-Content $manifestPath -Encoding utf8
        Set-Content (Join-Path $template 'stray.txt') 'unexpected' -Encoding utf8
        $configPath = Join-Path $root 'config.json'
        [ordered]@{ ManagedRoot=$root; TemplateManifestPath=$manifestPath } | ConvertTo-Json | Set-Content $configPath -Encoding utf8
        $layoutReport = Join-Path $TestDrive 'layout-rejected.json'
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMActiveManifest.ps1') -ConfigPath $configPath -ReportPath $layoutReport | Out-Null
        (Get-Content $layoutReport -Raw | ConvertFrom-Json).status | Should -Be 'planned'

        $splitRoot = Join-Path $TestDrive 'split-managed\templates'
        $active = Join-Path $splitRoot 'win11-25h2'; $defective = Join-Path $splitRoot 'defective'; $good = Join-Path $splitRoot 'good'
        New-Item -ItemType Directory -Path $active,$defective,$good -Force | Out-Null
        Set-Content (Join-Path $active 'win11-25h2.vhdx') 'image' -Encoding utf8
        Set-Content (Join-Path $active 'stray.txt') 'unexpected' -Encoding utf8
        [ordered]@{templateVersion='1.4.0'} | ConvertTo-Json | Set-Content (Join-Path $defective 'manifest.json') -Encoding utf8
        Set-Content (Join-Path $good 'win11-25h2.vhdx') 'good-image' -Encoding utf8
        [ordered]@{templateVersion='1.2.0';sha256='0000'} | ConvertTo-Json | Set-Content (Join-Path $good 'manifest.json') -Encoding utf8
        $splitConfig = Join-Path $TestDrive 'split-config.json'
        [ordered]@{ManagedRoot=(Split-Path -Parent $splitRoot);TemplateManifestPath=(Join-Path $good 'manifest.json')} |
            ConvertTo-Json | Set-Content $splitConfig -Encoding utf8
        $splitReport = Join-Path $TestDrive 'split-layout-rejected.json'
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMSplitState.ps1') -ConfigPath $splitConfig -ReportPath $splitReport | Out-Null
        (Get-Content $splitReport -Raw | ConvertFrom-Json).error | Should -Be 'unexpected_layout_win11-25h2'

        Mock -CommandName Get-Item -MockWith { [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint } } `
            -ParameterFilter { $LiteralPath -eq $template }
        $reparseReport = Join-Path $TestDrive 'reparse-rejected.json'
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMActiveManifest.ps1') -ConfigPath $configPath -ReportPath $reparseReport | Out-Null
        (Get-Content $reparseReport -Raw | ConvertFrom-Json).error | Should -Be 'reparse_point_rejected'
    }

    It 'requires explicit stale-state targets and only changes selected records' {
        $root = Join-Path $TestDrive 'managed'; New-Item -ItemType Directory -Path $root -Force | Out-Null
        $statePath = Join-Path $root 'provisioning-jobs.json'
        @(
            [ordered]@{ name = 'selected'; state = 'streaming_setup' },
            [ordered]@{ name = 'untouched'; state = 'streaming_setup' }
        ) | ConvertTo-Json | Set-Content $statePath -Encoding utf8
        $configPath = Join-Path $root 'config.json'
        [ordered]@{ ManagedRoot = $root; ProvisioningStatePath = $statePath } |
            ConvertTo-Json | Set-Content $configPath -Encoding utf8
        $reportPath = Join-Path $TestDrive 'stale-plan.json'
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMStaleProvisioningState.ps1') `
            -ConfigPath $configPath -ReportPath $reportPath -TargetName selected | Out-Null
        $records = @(Get-Content $statePath -Raw | ConvertFrom-Json)
        $records[0].state | Should -Be 'streaming_setup'
        $records[1].state | Should -Be 'streaming_setup'
        @((Get-Content $reportPath -Raw | ConvertFrom-Json).targetNames) | Should -Be @('selected')
    }

    It 'keeps split, stale, and v12 workflows non-mutating without Execute' {
        $root = Join-Path $TestDrive 'all-managed'; $templates = Join-Path $root 'templates'
        $active = Join-Path $templates 'win11-25h2'; $good = Join-Path $templates 'good'
        New-Item -ItemType Directory -Path $active,$good -Force | Out-Null
        $activeImage = Join-Path $active 'win11-25h2.vhdx'; $goodImage = Join-Path $good 'win11-25h2.vhdx'
        [IO.File]::WriteAllBytes($activeImage, [byte[]](1..8)); [IO.File]::WriteAllBytes($goodImage, [byte[]](9..16))
        $activeHash = (Get-FileHash $activeImage).Hash; $goodHash = (Get-FileHash $goodImage).Hash
        [ordered]@{templateVersion='1.4.0';sha256=$activeHash} | ConvertTo-Json | Set-Content (Join-Path $active 'manifest.json') -Encoding utf8
        [ordered]@{templateVersion='1.2.0';sha256=$goodHash} | ConvertTo-Json | Set-Content (Join-Path $good 'manifest.json') -Encoding utf8
        $config = Join-Path $root 'config.json'
        [ordered]@{ManagedRoot=$root;TemplateManifestPath=(Join-Path $active 'manifest.json')} | ConvertTo-Json | Set-Content $config -Encoding utf8
        $beforeDirs = (Get-ChildItem $templates -Directory -Force | Select-Object -ExpandProperty Name | Sort-Object) -join ','
        $report = Join-Path $TestDrive 'Restore-EpicVMV12Active.ps1.json'
        & (Join-Path $script:RepoRoot 'scripts\Restore-EpicVMV12Active.ps1') -ConfigPath $config -ReportPath $report -TemplateRoot $templates -DefectiveTemplateName defective -GoodTemplateName good | Out-Null
        (Get-Content $report -Raw | ConvertFrom-Json).status | Should -Be 'planned'
        ((Get-ChildItem $templates -Directory -Force | Select-Object -ExpandProperty Name | Sort-Object) -join ',') | Should -Be $beforeDirs

        $splitTemplates = Join-Path $root 'split-templates'; $splitActive = Join-Path $splitTemplates 'win11-25h2'; $splitDefective = Join-Path $splitTemplates 'defective'; $splitGood = Join-Path $splitTemplates 'good'
        New-Item -ItemType Directory -Path $splitActive,$splitDefective,$splitGood -Force | Out-Null
        Set-Content (Join-Path $splitActive 'win11-25h2.vhdx') 'image' -Encoding utf8
        [ordered]@{templateVersion='1.4.0'} | ConvertTo-Json | Set-Content (Join-Path $splitDefective 'manifest.json') -Encoding utf8
        $splitGoodImage = Join-Path $splitGood 'win11-25h2.vhdx'; Set-Content $splitGoodImage 'good-image' -Encoding utf8
        $splitHash = (Get-FileHash $splitGoodImage).Hash
        [ordered]@{templateVersion='1.2.0';sha256=$splitHash} | ConvertTo-Json | Set-Content (Join-Path $splitGood 'manifest.json') -Encoding utf8
        $splitConfig = Join-Path $root 'split-config.json'; [ordered]@{ManagedRoot=$root;TemplateManifestPath=(Join-Path $splitGood 'manifest.json')} | ConvertTo-Json | Set-Content $splitConfig -Encoding utf8
        $splitReport = Join-Path $TestDrive 'split-plan.json'
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMSplitState.ps1') -ConfigPath $splitConfig -ReportPath $splitReport -TemplateRoot $splitTemplates -DefectiveTemplateName defective -GoodTemplateName good | Out-Null
        (Get-Content $splitReport -Raw | ConvertFrom-Json).status | Should -Be 'planned'

        $statePath = Join-Path $root 'provisioning-jobs.json'
        @([ordered]@{name='selected';state='streaming_setup'}) | ConvertTo-Json | Set-Content $statePath -Encoding utf8
        [ordered]@{ManagedRoot=$root;ProvisioningStatePath=$statePath} | ConvertTo-Json | Set-Content $config -Encoding utf8
        $beforeState = Get-Content $statePath -Raw
        $staleReport = Join-Path $TestDrive 'stale-whatif.json'
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMStaleProvisioningState.ps1') -ConfigPath $config -ReportPath $staleReport -TargetName selected -Execute -WhatIf -Confirm:$false | Out-Null
        (Get-Content $staleReport -Raw | ConvertFrom-Json).status | Should -Be 'whatif'
        (Get-Content $statePath -Raw).Trim() | Should -Be $beforeState.Trim()
    }

    It 'creates a timestamped backup in an isolated execute fixture' {
        $root = Join-Path $TestDrive 'managed'; $template = Join-Path $root 'templates\win11-25h2'
        New-Item -ItemType Directory -Path $template -Force | Out-Null
        $image = Join-Path $template 'win11-25h2.vhdx'; [IO.File]::WriteAllBytes($image, [byte[]](1..16))
        $hash = (Get-FileHash $image -Algorithm SHA256).Hash
        $manifestPath = Join-Path $template 'manifest.json'
        [ordered]@{ templateVersion='1.4.0'; imagePath='wrong.vhdx'; sha256=$hash } |
            ConvertTo-Json | Set-Content $manifestPath -Encoding utf8
        $configPath = Join-Path $root 'config.json'
        [ordered]@{ ManagedRoot=$root; TemplateManifestPath=$manifestPath } |
            ConvertTo-Json | Set-Content $configPath -Encoding utf8
        $reportPath = Join-Path $TestDrive 'execute.json'
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMActiveManifest.ps1') `
            -ConfigPath $configPath -ReportPath $reportPath -Execute -Confirm:$false | Out-Null
        $result = Get-Content $reportPath -Raw | ConvertFrom-Json
        $result.status | Should -Be 'ok'; Test-Path $result.backupPath | Should -BeTrue
        (Get-Content $manifestPath -Raw) | Should -Match 'win11-25h2.vhdx'
    }

    It 'rolls back a mocked atomic replacement failure' {
        $root = Join-Path $TestDrive 'managed'; New-Item -ItemType Directory -Path $root -Force | Out-Null
        $statePath = Join-Path $root 'provisioning-jobs.json'
        @([ordered]@{ name = 'selected'; state = 'streaming_setup' }) |
            ConvertTo-Json | Set-Content $statePath -Encoding utf8
        $configPath = Join-Path $root 'config.json'
        [ordered]@{ ManagedRoot = $root; ProvisioningStatePath = $statePath } |
            ConvertTo-Json | Set-Content $configPath -Encoding utf8
        $reportPath = Join-Path $TestDrive 'rollback.json'
        $original = Get-Content $statePath -Raw
        Mock -CommandName Move-Item -MockWith {
            if ($Destination -eq $statePath -and $LiteralPath -like '*.tmp-*') {
                throw 'injected_atomic_failure'
            }
            [IO.File]::Move($LiteralPath, $Destination, $true)
            return
        }
        & (Join-Path $script:RepoRoot 'scripts\Repair-EpicVMStaleProvisioningState.ps1') `
            -ConfigPath $configPath -ReportPath $reportPath -TargetName selected -Execute -Confirm:$false | Out-Null
        $result = Get-Content $reportPath -Raw | ConvertFrom-Json
        $result.rollback | Should -Be 'restored_backup'
        (Get-Content $statePath -Raw).Trim() | Should -Be $original.Trim()
    }
}
