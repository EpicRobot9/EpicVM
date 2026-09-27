param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$JobId)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\SharedGames.ps1"
function Get-EpicVMProperty($Object,$Name,$Default) { if($Object.ContainsKey($Name)) { return $Object[$Name] }; return $Default }
$path = Join-Path $script:GameLibraryRoot "jobs\$JobId.json"
$job = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
$mutex = [Threading.Mutex]::new($false,'Global\EpicVMGameLibrary')
$locked = $false
try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { throw 'Another shared-game setup is running. Wait for it to finish before retrying.' }
    $job.state='running'; Write-EpicVMGameJson $path $job
    switch ($job.action) {
        'inspect' { $r=Get-EpicVMGameRecipe $job.request.sourcePath; $r.Remove('files'); $job.result=$r }
        'import' { $job.result=Add-EpicVMSharedGame $job.request }
        'download' { $job.result=Add-EpicVMArchivedGame $job.request $JobId }
        'archive' { $job.result=Add-EpicVMArchivedGame $job.request $JobId }
        'codex' { $job.result=Invoke-EpicVMGameCodex $job.request $JobId }
        'update' {
            $library=Get-EpicVMGameLibrary
            $game=@($library.games | Where-Object id -EQ $job.request.id)
            if ($game.Count -ne 1) { throw 'Game was not found.' }
            $distribution=$game[0].ContainsKey('verifiedDistribution') -and $game[0].verifiedDistribution
            $job.result=Add-EpicVMSharedGame @{id=$game[0].id;title=$game[0].title;sourcePath=$game[0].sourcePath} -Distribution:$distribution
            # Existing VM releases stay pinned until their assignment is reapplied.
        }
        'assign' {
            $credentialPath=Join-Path $script:GameLibraryRoot "secrets\job-$JobId.dpapi"
            if(-not(Test-Path $credentialPath)){throw 'Apply games through Management to supply the configured guest operator securely.'}
            $bytes=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($credentialPath),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
            try{$operator=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json}finally{[Array]::Clear($bytes,0,$bytes.Length)}
            $credential=[PSCredential]::new($operator.username,(ConvertTo-SecureString $operator.password -AsPlainText -Force))
            $operator=$null
            $job.result=Set-EpicVMSharedGameAssignment -VmName $job.request.vmName -GameIds @($job.request.gameIds) -GuestCredential $credential
        }
    }
    $job.state='complete'
} catch { $job.state='failed'; $job.error=$_.Exception.Message }
finally {
    $credentialPath=Join-Path $script:GameLibraryRoot "secrets\job-$JobId.dpapi"
    if(Test-Path $credentialPath){Remove-Item -LiteralPath $credentialPath -Force}
    $job.finishedAt=[DateTime]::UtcNow.ToString('o')
    Write-EpicVMGameJson $path $job
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
