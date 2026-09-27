# Shared immutable releases. Only distribution content enters the library;
# each guest receives its own writable executable/launcher area and profile.
Set-StrictMode -Version Latest
$script:GameLibraryRoot = 'E:\EpicVM\game-library'

function Start-EpicVMGameJob($Request) {
    $action = [string](Get-EpicVMProperty $Request 'action' '')
    if ($action -notin @('import','assign','update','inspect','download','archive','codex')) { throw 'Unsupported game library action.' }
    if ($action -notin @('assign','inspect') -and [string](Get-EpicVMProperty $Request 'id' '') -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Invalid game ID.' }
    $id = [guid]::NewGuid().ToString('N')
    if($action -eq 'assign' -and $Request.ContainsKey('guestCredential')){
        $credentialPath=Join-Path $script:GameLibraryRoot "secrets\job-$id.dpapi"
        [IO.Directory]::CreateDirectory((Split-Path $credentialPath))|Out-Null
        $bytes=[Text.Encoding]::UTF8.GetBytes(($Request.guestCredential|ConvertTo-Json -Compress))
        try{[IO.File]::WriteAllBytes($credentialPath,[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine))}finally{[Array]::Clear($bytes,0,$bytes.Length)}
        & icacls.exe $credentialPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
        if($LASTEXITCODE -ne 0){Remove-Item -LiteralPath $credentialPath -Force;throw 'Could not protect the guest operator credential.'}
        $Request.Remove('guestCredential')
    }
    $path = Join-Path $script:GameLibraryRoot "jobs\$id.json"
    $job = @{id=$id;state='queued';action=$action;request=$Request;createdAt=[DateTime]::UtcNow.ToString('o')}
    Write-EpicVMGameJson $path $job
    $worker = Join-Path $PSScriptRoot 'SharedGamesWorker.ps1'
    Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+$worker+'"'),'-JobId',$id) | Out-Null
    return @{id=$id;state='queued';action=$action}
}

function Invoke-EpicVMGameCodex($Request,[string]$JobId) {
    $name=[string]$Request.gameName
    if (-not $name -or $name.Length -gt 120) { throw 'Supply a game name of at most 120 characters.' }
    $savedPath=Join-Path $script:GameLibraryRoot ('recipes\'+$Request.id+'.json')
    if (Test-Path -LiteralPath $savedPath) {
        $saved=Get-Content $savedPath -Raw | ConvertFrom-Json -AsHashtable
        if ($saved.status -eq 'ready' -and (Test-Path -LiteralPath $saved.sourcePath -PathType Container)) {
            return Add-EpicVMSharedGame @{id=$Request.id;title=$Request.title;sourcePath=$saved.sourcePath}
        }
    }
    $root=Join-Path $script:GameLibraryRoot "agent-work\$JobId"
    [IO.Directory]::CreateDirectory($root) | Out-Null
    # The logged-in host operator owns Codex authentication. The service never
    # reads or transports it and the agent gets no administrator token.
    $operator=(Get-CimInstance Win32_ComputerSystem).UserName
    if (-not $operator) { throw 'Sign in to the host desktop to use Codex setup.' }
    & icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' "${operator}:(OI)(CI)M" | Out-Null
    Write-EpicVMGameJson (Join-Path $root 'request.json') @{gameName=$name}
    $runner=Join-Path $PSScriptRoot 'SharedGamesCodex.ps1'
    $action=New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'pwsh.exe') -Argument ('-NoProfile -File "'+$runner+'" -WorkRoot "'+$root+'"')
    $principal=New-ScheduledTaskPrincipal -UserId $operator -LogonType Interactive -RunLevel Limited
    $task='EpicVM-GameCodex-'+$JobId
    Register-ScheduledTask -TaskName $task -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask $task
    try {
        $deadline=[DateTime]::UtcNow.AddMinutes(21)
        $resultPath=Join-Path $root 'result.json'
        while (-not (Test-Path -LiteralPath $resultPath)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'Codex setup timed out. Its workspace is retained for review.' }
            Start-Sleep 3
        }
        $result=Get-Content $resultPath -Raw | ConvertFrom-Json -AsHashtable
        Write-EpicVMGameJson (Join-Path $script:GameLibraryRoot ('recipes\'+$Request.id+'.json')) $result
        if ($result.status -ne 'ready') { throw ('Codex recipe needs review: '+$result.reason) }
        # Agent output is fallible. The deterministic importer remains the only
        # path into a shared release and enforces the same isolation checks.
        return Add-EpicVMSharedGame @{id=$Request.id;title=$Request.title;sourcePath=$result.sourcePath}
    } finally { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue }
}

function Expand-EpicVMGameArchive([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $total=0L
        if ($zip.Entries.Count -gt 200000) { throw 'The archive contains too many files.' }
        foreach ($entry in $zip.Entries) {
            $total += $entry.Length
            if ($total -gt 500GB) { throw 'The expanded archive exceeds the game library limit.' }
            $relative=$entry.FullName.Replace('/','\')
            if (-not $relative.TrimEnd('\')) { continue }
            $target=Resolve-EpicVMGameChild $Destination $relative
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Archive links are not supported.' }
            if (Test-EpicVMPrivateGamePath $relative) { continue }
            if ($relative.EndsWith('\')) { [IO.Directory]::CreateDirectory($target) | Out-Null; continue }
            [IO.Directory]::CreateDirectory((Split-Path $target)) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
        }
    } finally { $zip.Dispose() }
}

function Receive-EpicVMGameUpload($Request) {
    $id=[string](Get-EpicVMProperty $Request 'uploadId' '')
    $offset=[long](Get-EpicVMProperty $Request 'offset' 0)
    if (-not $id) { $id=[guid]::NewGuid().ToString('N') }
    if ($id -notmatch '^[a-f0-9]{32}$' -or $offset -lt 0 -or $offset -gt 100GB) { throw 'Invalid upload position.' }
    $path=Join-Path $script:GameLibraryRoot "uploads\$id.zip"
    [IO.Directory]::CreateDirectory((Split-Path $path)) | Out-Null
    $bytes=[Convert]::FromBase64String([string](Get-EpicVMProperty $Request 'chunk' ''))
    if ($bytes.Length -gt 384KB) { throw 'Upload chunks must be at most 384 KiB.' }
    $stream=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        if ($stream.Length -ne $offset) { throw 'Upload position changed. Start a new upload.' }
        $stream.Position=$offset; $stream.Write($bytes,0,$bytes.Length)
        return @{uploadId=$id;offset=$stream.Position}
    } finally {$stream.Dispose()}
}

function Add-EpicVMArchivedGame($Request, [string]$JobId) {
    $stage=Join-Path $script:GameLibraryRoot "staging\$JobId"
    if ($Request.action -eq 'download') {
        $uri=[Uri]$Request.url
        if ($uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.IsLoopback) { throw 'Use an HTTPS distribution download URL.' }
        if ([string]$Request.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'A vendor SHA-256 checksum is required for downloads.' }
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        $archive=Join-Path $stage 'download.zip'
        Invoke-WebRequest -Uri $uri -OutFile $archive -TimeoutSec 1800
    } else {
        if ([string]$Request.uploadId -notmatch '^[a-f0-9]{32}$') { throw 'Invalid upload ID.' }
        $archive=Join-Path $script:GameLibraryRoot ('uploads\'+$Request.uploadId+'.zip')
    }
    $hash=(Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
    if ([string]$Request.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $hash -ne $Request.sha256) { throw 'The archive checksum does not match.' }
    $content=Join-Path $stage 'content'
    Expand-EpicVMGameArchive $archive $content
    $relative=[string](Get-EpicVMProperty $Request 'subfolder' '')
    $source=if($relative){Resolve-EpicVMGameChild $content $relative}else{$content}
    return Add-EpicVMSharedGame @{id=$Request.id;title=$Request.title;sourcePath=$source} -Distribution
}

function Write-EpicVMGameJson($Path, $Value) {
    [IO.Directory]::CreateDirectory((Split-Path $Path)) | Out-Null
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $Path, $true)
}

function Get-EpicVMGameLibrary {
    $path = Join-Path $script:GameLibraryRoot 'library.json'
    if (Test-Path -LiteralPath $path) { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable }
    return @{ schemaVersion=1; games=@(); assignments=@{} }
}

function Get-EpicVMGameLibraryView {
    $library=Get-EpicVMGameLibrary
    $library.jobs=@()
    $jobsRoot=Join-Path $script:GameLibraryRoot 'jobs'
    if(Test-Path -LiteralPath $jobsRoot){
        $library.jobs=@(Get-ChildItem -LiteralPath $jobsRoot -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 20 | ForEach-Object {
            $job=Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -AsHashtable
            $job.Remove('request');$job.Remove('result');$job
        })
    }
    $library.legacyGames=@()
    $legacy='E:\EpicVM\shared-games\catalog.json'
    if(Test-Path -LiteralPath $legacy){
        $old=Get-Content -LiteralPath $legacy -Raw | ConvertFrom-Json
        $library.legacyGames=@($old.games | Where-Object id -NotIn @($library.games | ForEach-Object {$_.id}) | ForEach-Object {
            @{id=$_.id;title=$_.title;status='legacy';sourcePath=$_.sharedLibraryPath}
        })
    }
    return $library
}

function Resolve-EpicVMGameChild([string]$Root, [string]$Relative) {
    if (-not $Relative -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) { throw 'Expected a relative content path.' }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative))
    if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Content path escapes its installation.' }
    $current = $path
    while ($current.Length -ge $base.TrimEnd('\').Length) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked installation content is not accepted.' }
        }
        $current = Split-Path $current
    }
    return $path
}

function Test-EpicVMPrivateGamePath([string]$Relative) {
    return $Relative -match '(?i)(^|[\\/])(UserData|User Data|userdata|webcache\w*|cache|caches|logs?|Saved|Saves?|screenshots?|ScreenShot|Selfie|screenrecord|crashdumps?|Cookies|Local Storage|Session Storage|IndexedDB|GPUCache|DawnCache|loginusers\.vdf|config\.vdf|ssfn\w*|.*\.(log|dmp|sav)|.*(token|cookie|session|credential).*|\.git)([\\/]|$)'
}

function Get-EpicVMGameRecipe([string]$SourcePath, [switch]$Distribution) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) { throw 'The installation folder does not exist on this host.' }
    $source = (Get-Item -LiteralPath $SourcePath).FullName
    if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Choose the real installation folder, not a link.' }
    $recipe = @{ sourcePath=$source; kind=''; exe=''; contentLinks=@(); files=@(); excludedCount=0 }
    # HoYoPlay's versioned Qt/CEF payload is separate from user profile state.
    # Never import launcher root config, game-account databases, or host AppData.
    $launcherVersions = @(Get-ChildItem -LiteralPath $source -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'HYP.exe') })
    if ($launcherVersions.Count -eq 1) {
        $source = $launcherVersions[0].FullName
        $recipe.sourcePath = $source
    }
    $manifest = Join-Path $source 'pkg_version'
    if ((Test-Path (Join-Path $source 'HYP.exe')) -and (Test-Path (Join-Path $source 'Qt5Core.dll'))) {
        $recipe.kind = 'qt-cef-versioned-launcher'
        $recipe.files = @(Get-ChildItem -LiteralPath $source -File | Where-Object { $_.Extension -in @('.exe','.dll','.pak','.bin') -or $_.Name -in @('icudtl.dat','icudt71l.dat','app.conf.dat','vk_swiftshader_icd.json') } | ForEach-Object Name)
        foreach ($dir in @('bearer','ico','imageformats','platforms','resources','styles')) {
            if (Test-Path (Join-Path $source $dir)) { $recipe.files += @(Get-ChildItem -LiteralPath (Join-Path $source $dir) -File -Recurse | ForEach-Object { [IO.Path]::GetRelativePath($source,$_.FullName) }) }
        }
        # The outer bootstrap expects a version subfolder. This release already
        # contains the version payload, so start its actual launcher directly.
        $candidates = @('HYP.exe')
    } elseif (Test-Path -LiteralPath $manifest) {
        $recipe.kind = 'package-manifest'
        $recipe.contentLinks = @(Get-ChildItem -LiteralPath $source -Directory | Where-Object Name -Like '*_Data' | ForEach-Object Name)
        $recipe.files = @(Get-Content -LiteralPath $manifest | ForEach-Object {
            $entry = $_ | ConvertFrom-Json
            $relative = [string]$entry.remoteName
            $file = Resolve-EpicVMGameChild $source $relative
            if (-not (Test-EpicVMPrivateGamePath $relative)) {
                if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "The installed distribution is incomplete: $relative"}
                $relative
            }
        })
        $candidates = @($recipe.files | Where-Object { $_ -notmatch '[\\/]' -and $_ -match '\.exe$' -and $_ -notmatch 'Crash|unins|setup' })
    } elseif ((Test-Path (Join-Path $source 'lime.ndll')) -and (Test-Path (Join-Path $source 'assets'))) {
        $recipe.kind = 'openfl'
        $recipe.contentLinks = @('assets','mods','lua','plugins','manifest') | Where-Object { Test-Path (Join-Path $source $_) }
        $recipe.files = @(Get-ChildItem -LiteralPath $source -File | Where-Object Extension -In '.exe','.dll','.ndll','.ico' | ForEach-Object Name)
        foreach ($dir in $recipe.contentLinks) {
            $recipe.files += @(Get-ChildItem -LiteralPath (Join-Path $source $dir) -Recurse -File -Force | ForEach-Object { [IO.Path]::GetRelativePath($source,$_.FullName) })
        }
        # Small portable games are materialized locally from the shared release.
        # Native media plugins and engines often require local filesystem semantics.
        $recipe.contentLinks = @()
        $candidates = @($recipe.files | Where-Object { $_ -notmatch '[\\/]' -and $_ -match '\.exe$' })
    } elseif (Test-Path (Join-Path $source 'Engine')) {
        $projects = @(Get-ChildItem -LiteralPath $source -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'Content\Paks') })
        if ($projects.Count -ne 1) { throw 'A single Unreal packaged project could not be identified.' }
        $project = $projects[0].Name
        $recipe.kind = 'unreal-package'
        $roots = @('Engine', "$project\Binaries", "$project\Content", "$project\Plugins", 'PatcherSDK', 'PxCrashSDK')
        $recipe.contentLinks = @("$project\Content", 'Engine\Content')
        foreach ($dir in $roots) {
            if (Test-Path (Join-Path $source $dir)) {
                $recipe.files += @(Get-ChildItem -LiteralPath (Join-Path $source $dir) -Recurse -File -Force | ForEach-Object { [IO.Path]::GetRelativePath($source,$_.FullName) })
            }
        }
        # Packaged distribution updater metadata, not launcher UserData.
        if (Test-Path (Join-Path $source 'PatcherConfig\Patch_Windows.json')) { $recipe.files += 'PatcherConfig\Patch_Windows.json' }
        $candidates = @($recipe.files | Where-Object { [IO.Path]::GetDirectoryName($_) -eq "$project\Binaries\Win64" -and $_ -match '\.exe$' -and $_ -notmatch 'Crash|unins|setup|helper' })
    } elseif ($Distribution) {
        # Only a newly extracted, checksum-verified distribution reaches this
        # branch. An arbitrary host installation is never treated as clean.
        $recipe.kind='verified-distribution'
        $recipe.files=@(Get-ChildItem -LiteralPath $source -File -Recurse -Force | ForEach-Object {[IO.Path]::GetRelativePath($source,$_.FullName)})
        $candidates=@($recipe.files | Where-Object {$_ -notmatch '[\\/]' -and $_ -match '\.exe$' -and $_ -notmatch 'unins|setup|crash|helper|update'})
    } else {
        throw 'No reusable installation recipe matches this folder. Supply a clean distribution or request Codex setup.'
    }
    if ($candidates.Count -ne 1) { throw 'The installation has multiple launch candidates; a reviewed recipe is required.' }
    $recipe.exe = $candidates[0]
    $originalCount = $recipe.files.Count
    $recipe.files = @($recipe.files | Where-Object { -not (Test-EpicVMPrivateGamePath $_) } | Sort-Object -Unique)
    $recipe.excludedCount = $originalCount - $recipe.files.Count
    $size = 0L
    foreach ($relative in $recipe.files) { $size += (Get-Item -LiteralPath (Resolve-EpicVMGameChild $source $relative)).Length }
    $recipe.sizeBytes = $size
    return $recipe
}

function Add-EpicVMSharedGame($Request, [switch]$Distribution) {
    $id = [string]$Request.id
    if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Use a game ID containing lowercase letters, numbers, and hyphens.' }
    $title = [string]$Request.title
    if (-not $title -or $title.Length -gt 120) { throw 'A game title of at most 120 characters is required.' }
    $recipe = Get-EpicVMGameRecipe ([string]$Request.sourcePath) -Distribution:$Distribution
    $release = [guid]::NewGuid().ToString('N')
    $target = Join-Path $script:GameLibraryRoot "releases\$id\$release"
    [IO.Directory]::CreateDirectory($target) | Out-Null
    foreach ($relative in $recipe.files) {
        $source = Resolve-EpicVMGameChild $recipe.sourcePath $relative
        $dest = Resolve-EpicVMGameChild $target $relative
        [IO.Directory]::CreateDirectory((Split-Path $dest)) | Out-Null
        [IO.File]::Copy($source, $dest, $false)
    }
    $game = @{ id=$id; title=$title; release=$release; sourcePath=$recipe.sourcePath; recipe=$recipe.kind;
        exe=$recipe.exe; contentLinks=@($recipe.contentLinks); sizeBytes=$recipe.sizeBytes;
        releasePath=$target; updatedAt=[DateTime]::UtcNow.ToString('o'); isolation='distribution-content-only'; available=$true }
    $game.sourcePath=[string]$Request.sourcePath
    $game.verifiedDistribution=[bool]$Distribution
    Write-EpicVMGameJson (Join-Path $target '.epicvm-manifest.json') @{ files=$recipe.files; recipe=$recipe.kind; excludedCount=$recipe.excludedCount }
    $library = Get-EpicVMGameLibrary
    $previous = @($library.games | Where-Object id -EQ $id)
    if ($previous.Count) {
        $game.previousRelease = $previous[0].release
        if($previous[0].ContainsKey('compatibility')){$game.compatibility=$previous[0].compatibility}
    }
    if($Request.ContainsKey('compatibility')){
        if($Request.compatibility -notin @('native','mesa-software')){throw 'Unknown compatibility runtime.'}
        $game.compatibility=$Request.compatibility
    }
    $library.games = @($library.games | Where-Object id -NE $id) + @($game)
    Write-EpicVMGameJson (Join-Path $script:GameLibraryRoot 'library.json') $library
    return $game
}

function Set-EpicVMSharedGameAssignment([string]$VmName, [string[]]$GameIds, [switch]$Launch, [PSCredential]$GuestCredential) {
    $vm = Get-VM -Name $VmName -ErrorAction Stop
    if ([string]$vm.State -ne 'Running') { throw 'Start the VM before changing its installed games.' }
    $library = Get-EpicVMGameLibrary
    $games = @()
    foreach ($id in @($GameIds | Select-Object -Unique)) {
        $found = @($library.games | Where-Object id -EQ $id)
        if ($found.Count -ne 1) { throw "Unknown game: $id" }
        $games += $found[0]
    }
    $key = $vm.Id.ToString('N').Substring(0,16)
    $shareName = "EpicVM-$key`$"
    $account = "evg-$key"
    $shareRoot = Join-Path $script:GameLibraryRoot "guests\$key"
    [IO.Directory]::CreateDirectory($shareRoot) | Out-Null
    $secretPath = Join-Path $script:GameLibraryRoot "secrets\$key.dpapi"
    if (Test-Path -LiteralPath $secretPath) {
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($secretPath),$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
        try { $secret=ConvertTo-SecureString ([Text.Encoding]::UTF8.GetString($bytes)) -AsPlainText -Force }
        finally { [Array]::Clear($bytes,0,$bytes.Length) }
        $shareCredential = [PSCredential]::new("$env:COMPUTERNAME\$account",$secret)
    }
    else {
        $secret = ConvertTo-SecureString ([Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36))) -AsPlainText -Force
        if (Get-LocalUser -Name $account -ErrorAction SilentlyContinue) { Set-LocalUser -Name $account -Password $secret }
        else { New-LocalUser -Name $account -Password $secret -PasswordNeverExpires -UserMayNotChangePassword -Description 'EpicVM read-only game content' | Out-Null }
        $shareCredential = [PSCredential]::new("$env:COMPUTERNAME\$account",$secret)
        [IO.Directory]::CreateDirectory((Split-Path $secretPath)) | Out-Null
        $bytes=[Text.Encoding]::UTF8.GetBytes($shareCredential.GetNetworkCredential().Password)
        try { [IO.File]::WriteAllBytes($secretPath,[Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)) }
        finally { [Array]::Clear($bytes,0,$bytes.Length) }
        & icacls.exe $secretPath /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    }
    & icacls.exe $shareRoot /grant "${account}:(OI)(CI)RX" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not grant guest library read access.' }
    if (-not (Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $shareName -Path $shareRoot -ReadAccess "$env:COMPUTERNAME\$account" -FullAccess 'BUILTIN\Administrators' -FolderEnumerationMode AccessBased | Out-Null
    }
    foreach ($link in @(Get-ChildItem -LiteralPath $shareRoot -Directory -Force)) {
        if (-not ($link.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unexpected non-link in the managed VM library.' }
        # Keep older releases of still-assigned games available to running
        # processes; new assignments receive release-specific content paths.
        $keep=$false
        foreach($game in $games){if($link.Name -eq $game.id -or $link.Name.StartsWith($game.id+'--')){$keep=$true}}
        if($keep){continue}
        # Delete the junction itself, never traverse or recursively delete its target.
        [IO.Directory]::Delete($link.FullName)
    }
    $guestGames = @()
    foreach ($game in $games) {
        & icacls.exe $game.releasePath /grant "${account}:(OI)(CI)RX" /T /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not grant game content read access.' }
        $contentName=$game.id+'--'+$game.release
        $contentPath=Join-Path $shareRoot $contentName
        if(-not(Test-Path -LiteralPath $contentPath)){New-Item -ItemType Junction -Path $contentPath -Target $game.releasePath | Out-Null}
        $compatibility=if($game.ContainsKey('compatibility')){$game.compatibility}else{'native'}
        $guestGames += @{ id=$game.id; title=$game.title; exe=$game.exe; release=$game.release; contentName=$contentName; contentLinks=$game.contentLinks; compatibility=$compatibility }
    }
    Write-EpicVMGameJson (Join-Path $shareRoot 'catalog.json') @{ games=$guestGames }
    if(-not $GuestCredential){
        . 'C:\ProgramData\EpicVM\agent\guest-cred.ps1'
        $GuestCredential=$script:EpicVmGuestCredential
    }
    $hostAddress = '100.72.220.117'
    $unc = "\\$hostAddress\$shareName"
    $result = Invoke-Command -VMName $VmName -Credential $GuestCredential -ArgumentList $unc,$hostAddress,$shareCredential.UserName,$shareCredential.GetNetworkCredential().Password,(ConvertTo-Json -InputObject @($guestGames) -Depth 10 -Compress),([bool]$Launch) -ScriptBlock {
        param($Unc,$HostAddress,$ShareUser,$SharePass,$GameJson,$Launch)
        $ErrorActionPreference = 'Stop'
        # These are VM-specific content-share credentials, never host launcher credentials.
        & cmdkey.exe "/add:$HostAddress" "/user:$ShareUser" "/pass:$SharePass" | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not store the VM library credential.' }
        & net.exe use $Unc "/user:$ShareUser" $SharePass /persistent:no | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not connect the VM game library.' }
        # PS-Direct/WinRM and the interactive desktop have separate logon tokens.
        # Establish credentials in the desktop token as well, and after every logon.
        $escapedUser = $ShareUser.Replace("'", "''")
        $escapedPass = $SharePass.Replace("'", "''")
        $connect = "& cmdkey.exe '/add:$HostAddress' '/user:$escapedUser' '/pass:$escapedPass' | Out-Null; & net.exe use '$Unc' '/persistent:no' | Out-Null"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($connect))
        $connectAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
        $connectPrincipal = New-ScheduledTaskPrincipal -UserId ([Environment]::UserName) -LogonType Interactive -RunLevel Limited
        $connectTrigger = New-ScheduledTaskTrigger -AtLogOn -User ([Environment]::UserName)
        Register-ScheduledTask -TaskName 'EpicVM-ConnectGameLibrary' -Action $connectAction -Principal $connectPrincipal -Trigger $connectTrigger -Force | Out-Null
        Start-ScheduledTask -TaskName 'EpicVM-ConnectGameLibrary'
        # Windows PowerShell 5.1 emits JSON arrays as a single pipeline object.
        $items = @($GameJson | ConvertFrom-Json | ForEach-Object { if($null -ne $_){$_} })
        $root = 'C:\ProgramData\EpicVM\games'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $managed = Join-Path $root 'assigned.json'
        $old = if (Test-Path $managed) { @(Get-Content $managed -Raw | ConvertFrom-Json | ForEach-Object { $_ }) } else { @() }
        foreach ($prior in $old) {
            if ($prior.id -notin @($items.id)) {
                $shortcut = Join-Path 'C:\Users\Public\Desktop' ("EpicVM - " + $prior.id + '.lnk')
                Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
                # Remove only files recorded by our distribution manifest. Keep
                # VM-created saves and profile data for a later reassignment.
                if ([string]$prior.id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Invalid previous assignment.' }
                $priorRoot=Join-Path $root $prior.id
                if (Test-Path -LiteralPath $priorRoot) {
                    foreach ($oldRelease in @(Get-ChildItem -LiteralPath $priorRoot -Directory)) {
                        $receipt=Join-Path $oldRelease.FullName '.epicvm-installed.json'
                        if (-not (Test-Path -LiteralPath $receipt)) { continue }
                        $installed=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
                        # Unlink managed content first, without traversing SMB or
                        # VM-local save junctions during distribution cleanup.
                        $pending=[Collections.Generic.Queue[string]]::new()
                        $pending.Enqueue($oldRelease.FullName)
                        while($pending.Count){
                            $directory=$pending.Dequeue()
                            foreach($child in @(Get-ChildItem -LiteralPath $directory -Directory -Force)){
                                if($child.Attributes -band [IO.FileAttributes]::ReparsePoint){[IO.Directory]::Delete($child.FullName)}else{$pending.Enqueue($child.FullName)}
                            }
                        }
                        foreach ($rel in $installed.files) {
                            $full=[IO.Path]::GetFullPath((Join-Path $oldRelease.FullName $rel))
                            if (-not $full.StartsWith($oldRelease.FullName+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid installed content receipt.' }
                            Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
                        }
                        foreach ($link in @(Get-ChildItem -LiteralPath $oldRelease.FullName -Directory -Force)) {
                            if ($link.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($link.FullName) }
                        }
                    }
                }
            }
        }
        $verification = @()
        foreach ($game in $items) {
            $local = Join-Path $root ($game.id + '\' + $game.release)
            $source = Join-Path $Unc $game.contentName
            New-Item -ItemType Directory -Path $local -Force | Out-Null
            foreach ($link in @(Get-ChildItem -LiteralPath $local -Directory -Force)) {
                if (($link.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $link.Name -notin @($game.contentLinks)) { [IO.Directory]::Delete($link.FullName) }
            }
            $manifest = Get-Content (Join-Path $source '.epicvm-manifest.json') -Raw | ConvertFrom-Json
            foreach ($relative in $manifest.files) {
                $relative=$relative.Replace('/','\')
                $linked = $false
                foreach ($dir in $game.contentLinks) { if ($relative.StartsWith($dir.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { $linked = $true; break } }
                if ($linked) { continue }
                $dest = Join-Path $local $relative
                New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
                if (-not (Test-Path -LiteralPath $dest)) { Copy-Item -LiteralPath (Join-Path $source $relative) -Destination $dest }
            }
            foreach ($dir in $game.contentLinks) {
                $dest = Join-Path $local $dir
                if (-not (Test-Path -LiteralPath (Join-Path $source $dir))) { continue }
                if (-not (Test-Path -LiteralPath $dest)) {
                    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
                    New-Item -ItemType SymbolicLink -Path $dest -Target (Join-Path $source $dir) | Out-Null
                }
            }
            $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $local '.epicvm-installed.json') -Encoding UTF8
            & icacls.exe $local /grant '*S-1-5-32-545:(OI)(CI)M' /Q | Out-Null
            $exe = Join-Path $local $game.exe
            # Mutable installation-local state survives release changes but
            # is created in this VM only. Host profiles never enter these paths.
            $stateRoot=Join-Path $root ('user-state\'+$game.id)
            foreach($folder in @('Saved','Saves','UserData')) {
                $statePath=Join-Path $stateRoot $folder
                New-Item -ItemType Directory -Path $statePath -Force | Out-Null
                $stateLink=Join-Path (Split-Path $exe) $folder
                if(-not(Test-Path -LiteralPath $stateLink)){New-Item -ItemType Junction -Path $stateLink -Target $statePath | Out-Null}
            }
            & icacls.exe $stateRoot /grant '*S-1-5-32-545:(OI)(CI)M' /T /Q | Out-Null
            $launchExe=$exe; $launchArguments=''
            if($game.compatibility -eq 'mesa-software') {
                $runtime=Join-Path $root 'runtimes\mesa-26.2.0'
                New-Item -ItemType Directory -Path $runtime -Force | Out-Null
                $archive=Join-Path $runtime 'mesa.7z'
                if(-not(Test-Path -LiteralPath $archive)){Invoke-WebRequest -UseBasicParsing 'https://github.com/pal1000/mesa-dist-win/releases/download/26.2.0/mesa3d-26.2.0-release-msvc.7z' -OutFile $archive}
                if((Get-FileHash $archive -Algorithm SHA256).Hash -ne 'dcb2719ef346dab5b609fcb193a5f13cfc4b0502e3f4de1ad43d349477402f47'){throw 'Compatibility runtime checksum failed.'}
                if(-not(Test-Path "$runtime\x64\opengl32.dll")){& tar.exe -xf $archive -C $runtime;if($LASTEXITCODE -ne 0){throw 'Runtime extraction failed.'}}
                foreach($file in @('opengl32.dll','libgallium_wgl.dll')){
                    $runtimeFile=Join-Path "$runtime\x64" $file
                    $installedFile=Join-Path (Split-Path $exe) $file
                    if(-not(Test-Path $installedFile) -or (Get-FileHash $installedFile).Hash -ne (Get-FileHash $runtimeFile).Hash){Copy-Item -LiteralPath $runtimeFile -Destination $installedFile -Force}
                }
                $launchExe='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
                $launchCode="`$env:GALLIUM_DRIVER='llvmpipe'; Start-Process -FilePath '"+$exe.Replace("'","''")+"' -WorkingDirectory '"+(Split-Path $exe).Replace("'","''")+"'"
                $launchArguments='-NoProfile -WindowStyle Hidden -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launchCode))
            }
            $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path 'C:\Users\Public\Desktop' ("EpicVM - " + $game.id + '.lnk')))
            $shortcut.TargetPath = $launchExe
            $shortcut.Arguments = $launchArguments
            $shortcut.WorkingDirectory = Split-Path $exe
            $shortcut.Description = $game.title
            $shortcut.Save()
            $verification += @{ id=$game.id; exeVisible=(Test-Path -LiteralPath $exe); contentVisible=(Test-Path -LiteralPath $source); localPath=$local }
            if ($Launch) {
                $taskName = 'EpicVM-Launch-' + $game.id
                $action = if($launchArguments){New-ScheduledTaskAction -Execute $launchExe -Argument $launchArguments -WorkingDirectory (Split-Path $exe)}else{New-ScheduledTaskAction -Execute $exe -WorkingDirectory (Split-Path $exe)}
                $principal = New-ScheduledTaskPrincipal -UserId ([Environment]::UserName) -LogonType Interactive -RunLevel Limited
                Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
                Start-ScheduledTask -TaskName $taskName
            }
        }
        ConvertTo-Json -InputObject @($items) -Depth 8 | Set-Content $managed -Encoding UTF8
        $blocked = $false
        try { [IO.File]::WriteAllText((Join-Path $Unc '.write-probe'),'x') } catch { $blocked = $true }
        return @{ games=$verification; readOnlyEnforced=$blocked }
    }
    if (-not $result.readOnlyEnforced) { throw 'Guest content write protection failed.' }
    $library.assignments[$VmName] = @{ gameIds=@($GameIds); appliedAt=[DateTime]::UtcNow.ToString('o') }
    Write-EpicVMGameJson (Join-Path $script:GameLibraryRoot 'library.json') $library
    return $result
}
