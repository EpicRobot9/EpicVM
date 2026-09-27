# EpicVM's native Windows gaming adapter. MultiSeat owns the session, display,
# stream and teardown; this file only applies EpicVM's catalog and owner policy.
$script:HostGamingRoot = 'C:\ProgramData\EpicVM\host-gaming'
$script:HostGamingCatalog = Join-Path $script:HostGamingRoot 'games.json'
$script:MultiSeatBase = 'http://127.0.0.1:9550'

function Initialize-EpicVMHostGaming {
    if (-not (Test-Path -LiteralPath $script:HostGamingRoot)) {
        [IO.Directory]::CreateDirectory($script:HostGamingRoot) | Out-Null
    }
    & icacls.exe $script:HostGamingRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Host gaming catalog permissions could not be secured.' }
}

function Invoke-EpicVMMultiSeat([string]$Method, [string]$Path, $Payload = $null) {
    if ($Path -notmatch '^/api/(seats|accounts|system)/[a-zA-Z0-9/_-]*$') { throw 'Invalid seat API path.' }
    $keyPath = 'C:\ProgramData\MultiSeat\api-key.txt'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw 'MultiSeat is not installed with API authentication enabled.' }
    $key = [IO.File]::ReadAllText($keyPath).Trim()
    if (-not $key) { throw 'MultiSeat API key is empty.' }
    $args = @{ Uri = ($script:MultiSeatBase + $Path); Method = $Method; Headers = @{'X-MultiSeat-Key' = $key}; TimeoutSec = 90; ErrorAction = 'Stop' }
    if ($null -ne $Payload) {
        $args.ContentType = 'application/json'
        $args.Body = ConvertTo-Json -InputObject $Payload -Depth 8 -Compress
    }
    try {
        $response = Invoke-WebRequest @args
        if (-not $response.Content) { return $null }
        return ConvertFrom-Json -InputObject $response.Content -AsHashtable
    } catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        throw "Seat service request failed ($code): $Method $Path"
    } finally { $key = $null }
}

function Get-EpicVMHostGamingCatalog {
    Initialize-EpicVMHostGaming
    if (Test-Path -LiteralPath $script:HostGamingCatalog) {
        return @(Get-Content -LiteralPath $script:HostGamingCatalog -Raw | ConvertFrom-Json -AsHashtable)
    }
    return @()
}

function Get-EpicVMHostGamingAccount([string]$Owner) {
    if ($Owner -notmatch '^(portal|dashboard-config):[a-zA-Z0-9_.@-]{1,128}$') { throw 'Invalid EpicVM owner.' }
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Owner.ToLowerInvariant()))
    $hex = [Convert]::ToHexString($hash).ToLowerInvariant()
    $legacy = 'evseat_' + $hex.Substring(0, 13)
    # Existing seats keep their Windows profile; only newly created accounts
    # receive the readable name. MultiSeat caps names at 20 characters.
    if (Get-LocalUser -Name $legacy -ErrorAction SilentlyContinue) { return $legacy }
    $parts = $Owner.Split(':', 2)
    $label = $parts[1].ToLowerInvariant()
    if ($parts[0] -eq 'portal' -and $label -match '^[a-z0-9_]{1,13}$' -and $label -notmatch '^cfg_') {
        return 'EpicVM_' + $label
    }
    if ($parts[0] -eq 'dashboard-config') { return 'EpicVM_cfg_' + $hex.Substring(0, 9) }
    $safe = [regex]::Replace($label, '[^a-z0-9_]', '_').Trim('_')
    if (-not $safe) { $safe = 'user' }
    return 'EpicVM_' + $safe.Substring(0, [Math]::Min(8, $safe.Length)) + '_' + $hex.Substring(0, 4)
}

function Get-EpicVMApolloAuth([int]$PortBase, [switch]$Create) {
    $path = Join-Path $script:HostGamingRoot 'apollo-auth.json'
    if (Test-Path -LiteralPath $path) {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $cipher = [Convert]::FromBase64String([string]$record.cipher)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($cipher, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        try { return @{username=[string]$record.username;password=[Text.Encoding]::UTF8.GetString($plain)} }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    if (-not $Create) { throw 'Seat streaming pairing is not initialized.' }
    if (Test-Path -LiteralPath 'C:\ProgramData\MultiSeat\apollo\shared_credentials.json') {
        throw 'Existing seat streaming credentials need administrator migration.'
    }
    $username = 'epicvm-seat-stream'
    $password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(42)) + 'aA1!'
    try {
        $body = @{currentUsername='';currentPassword='';newUsername=$username;newPassword=$password;confirmNewPassword=$password} | ConvertTo-Json -Compress
        $response = Invoke-RestMethod -Uri "https://127.0.0.1:$($PortBase+1)/api/password" -Method Post -ContentType 'application/json' -Body $body -SkipCertificateCheck -TimeoutSec 10
        if ($response.status -ne $true) { throw 'Seat streaming credential setup failed.' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($password)
        try { $cipher = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine) }
        finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        Write-EpicVMGameJson $path @{username=$username;cipher=[Convert]::ToBase64String($cipher)}
        return @{username=$username;password=$password}
    } catch { throw 'Seat streaming credential setup failed.' }
}

function Pair-EpicVMHostGaming($Request) {
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $pin = [string]$Request.pin
    if ($pin -notmatch '^\d{4}$') { throw 'Invalid stream pairing PIN.' }
    $view = Get-EpicVMHostGamingView
    $seats = @($view.seats | Where-Object { $_.accountName -ieq $account -and $_.status -in @('Ready','Streaming') })
    if ($seats.Count -ne 1) { throw 'The owner has no ready seat.' }
    $auth = Get-EpicVMApolloAuth ([int]$seats[0].portBase)
    try {
        $base = "https://127.0.0.1:$([int]$seats[0].portBase+1)"
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri "$base/api/login" -Method Post -WebSession $session -ContentType 'application/json' -Body (@{username=$auth.username;password=$auth.password}|ConvertTo-Json -Compress) -SkipCertificateCheck -TimeoutSec 10 | Out-Null
        $response = Invoke-RestMethod -Uri "$base/api/pin" -Method Post -WebSession $session -ContentType 'application/json' -Body (@{pin=$pin;name='EpicVMWeb'}|ConvertTo-Json -Compress) -SkipCertificateCheck -TimeoutSec 20
        if ($response.status -ne $true) { throw 'Seat rejected the pairing PIN.' }
        return @{ok=$true;paired=$true}
    } finally { $auth.password=$null; $session=$null }
}

function Get-EpicVMHostGamingView {
    $installed = [bool](Get-Service MultiSeatService -ErrorAction SilentlyContinue)
    $service = Get-Service MultiSeatService -ErrorAction SilentlyContinue
    $games = @(Get-EpicVMHostGamingCatalog | ForEach-Object { @{id=$_.id;title=$_.title;available=(Test-Path -LiteralPath $_.executable -PathType Leaf)} })
    if (-not $service -or $service.Status -ne 'Running') {
        return @{ok=$true;apiVersion=3;installed=$installed;ready=$false;service=if($service){$service.Status.ToString()}else{'Missing'};games=$games;seats=@()}
    }
    $auth = Invoke-EpicVMMultiSeat GET '/api/system/auth'
    if ($auth.authEnabled -ne $true) { throw 'MultiSeat API authentication must be enabled.' }
    $displays = Invoke-EpicVMMultiSeat GET '/api/system/displays'
    $seats = @(Invoke-EpicVMMultiSeat GET '/api/seats/')
    # Without SudoVDA, Apollo can capture the physical desktop. Fail closed.
    return @{ok=$true;apiVersion=3;installed=$true;ready=($displays.sudoVdaFound -eq $true);service='Running';games=$games;seats=@($seats | ForEach-Object { @{id=$_.id;accountName=$_.accountName;status=$_.status;portBase=$_.portBase;sessionId=$_.sessionId;errorMessage=$_.errorMessage} })}
}

function Register-EpicVMHostGame($Request) {
    $id = [string]$Request.id
    $title = [string]$Request.title
    if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or -not $title -or $title.Length -gt 120) { throw 'Invalid game identity.' }
    $path = [IO.Path]::GetFullPath([string]$Request.executable)
    if ($path -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetExtension($path) -ine '.exe' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Choose an installed executable on this host.' }
    if ($path -match '(?i)\\(Users|AppData|Windows)\\') { throw 'Choose a machine-wide installation outside user profiles and Windows.' }
    $games = @(Get-EpicVMHostGamingCatalog | Where-Object { $_.id -ne $id })
    $games += @{id=$id;title=$title;executable=$path}
    Write-EpicVMGameJson $script:HostGamingCatalog $games
    return @{ok=$true;games=@($games | ForEach-Object { @{id=$_.id;title=$_.title;available=$true} })}
}

function Unregister-EpicVMHostGame($Request) {
    $id = [string]$Request.id
    if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Invalid game identity.' }
    $games = @(Get-EpicVMHostGamingCatalog | Where-Object { $_.id -ne $id })
    Write-EpicVMGameJson $script:HostGamingCatalog $games
    return @{ok=$true;games=@($games | ForEach-Object { @{id=$_.id;title=$_.title;available=(Test-Path -LiteralPath $_.executable -PathType Leaf)} })}
}

function Start-EpicVMHostSession($Request, [switch]$Desktop) {
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $id = ''
    $game = $null
    if (-not $Desktop) {
        $id = [string]$Request.gameId
        $games = @(Get-EpicVMHostGamingCatalog | Where-Object { $_.id -eq $id })
        if ($games.Count -ne 1) { throw 'Game is not in the host catalog.' }
        $game = $games[0]
        if (-not (Test-Path -LiteralPath $game.executable -PathType Leaf)) { throw 'The host game is unavailable.' }
    }
    $view = Get-EpicVMHostGamingView
    if (-not $view.ready) { throw 'Native gaming is not ready on this host.' }
    $seats = @($view.seats | Where-Object { $_.accountName -ieq $account })
    if ($seats.Count -gt 1) { throw 'More than one seat owns this account. Administrator recovery is required.' }
    if ($seats.Count -eq 1 -and $seats[0].status -eq 'Error') {
        # MultiSeat retains failed records for inspection. Retire only this
        # owner's failed seat before asking it to allocate a fresh one.
        Invoke-EpicVMMultiSeat DELETE ('/api/seats/' + $seats[0].id) | Out-Null
        $seats = @()
    }
    $newSeat = $false
    if (-not $seats.Count) {
        $accounts = @(Invoke-EpicVMMultiSeat GET '/api/accounts/')
        if ($account -notin @($accounts | ForEach-Object { $_.username })) {
            # A fresh seat password is sent only to the local service, which
            # protects it. No operator or launcher credentials are copied.
            $password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36)) + 'aA1!'
            try { Invoke-EpicVMMultiSeat POST '/api/accounts/' @{username=$account;password=$password} | Out-Null }
            finally { $password = $null }
        }
        $seat = Invoke-EpicVMMultiSeat POST '/api/seats/' @{accountName=$account;width=1920;height=1080;fps=60}
        $newSeat = $true
    } else {
        $seat = Invoke-EpicVMMultiSeat GET ('/api/seats/' + $seats[0].id)
    }
    try {
        if ($seat.status -notin @('Ready','Streaming')) { throw 'The seat is not ready to launch a game.' }
        $auth = Get-EpicVMApolloAuth ([int]$seat.portBase) -Create
        $auth.password = $null
        $sid = [string]$seat.id
        if (-not $Desktop) {
            Invoke-EpicVMMultiSeat POST "/api/seats/$sid/launch" @{executablePath=$game.executable;workingDirectory=(Split-Path -Parent $game.executable)} | Out-Null
        }
        return @{ok=$true;kind=if($Desktop){'desktop'}else{'game'};gameId=$id;seatId=$sid;status=$seat.status;portBase=$seat.portBase;streamHost=$env:COMPUTERNAME}
    } catch {
        if ($newSeat -and $seat.id) { try { Invoke-EpicVMMultiSeat DELETE ('/api/seats/' + $seat.id) | Out-Null } catch {} }
        throw
    }
}

function Start-EpicVMHostGame($Request) { return Start-EpicVMHostSession $Request }

function Start-EpicVMHostDesktop($Request) { return Start-EpicVMHostSession $Request -Desktop }

function Reveal-EpicVMHostAccountCredential($Request) {
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $accounts = @(Invoke-EpicVMMultiSeat GET '/api/accounts/')
    if ($account -notin @($accounts | Where-Object { $_.isManaged -eq $true } | ForEach-Object { $_.username })) {
        throw 'The owner has no managed Windows account.'
    }
    $result = Invoke-EpicVMMultiSeat POST ("/api/accounts/$account/credential/reveal")
    if (-not $result.password) { throw 'The seat account credential is unavailable.' }
    return @{ok=$true;accountName=$account;password=[string]$result.password}
}

function Stop-EpicVMHostGame($Request) {
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $view = Get-EpicVMHostGamingView
    foreach ($seat in @($view.seats | Where-Object { $_.accountName -ieq $account })) {
        Invoke-EpicVMMultiSeat DELETE ('/api/seats/' + $seat.id) | Out-Null
    }
    return @{ok=$true;status='stopped'}
}

function Recover-EpicVMHostGaming($Request) {
    $seatId = [string]$Request.seatId
    if ($seatId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Invalid seat identity.' }
    $view = Get-EpicVMHostGamingView
    $owned = @($view.seats | Where-Object { $_.id -eq $seatId -and $_.accountName -match '^(evseat_[0-9a-f]{13}|EpicVM_[a-z0-9_]{1,13})$' })
    if ($owned.Count -ne 1) { throw 'Seat is not managed by EpicVM.' }
    Invoke-EpicVMMultiSeat DELETE ('/api/seats/' + $seatId) | Out-Null
    return @{ok=$true;status='recovered';seatId=$seatId}
}
