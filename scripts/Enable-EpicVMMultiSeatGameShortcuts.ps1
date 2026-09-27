param([switch]$Apply)

$ErrorActionPreference = 'Stop'
$commonDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
$steam = 'C:\Program Files (x86)\Steam\steam.exe'
$epic = 'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win32\EpicGamesLauncher.exe'
$hoyo = 'D:\Games\Zenlesszero\HoYoPlay\launcher.exe'
$genshinGame = 'E:\Genshin\Genshin Impact game\GenshinImpact.exe'
$fnf = Get-ChildItem 'E:\EpicVM\game-library\releases\fnf-dustin' -Recurse -Filter dustin.exe -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
$games = @(
    @{Name='FNF Dustin';Target=$fnf;Args=''}
    @{Name='Fortnite';Target=$epic;Args='-uri=com.epicgames.launcher://apps/Fortnite?action=launch&silent=true'}
    @{Name='Rocket League';Target=$epic;Args='-uri=com.epicgames.launcher://apps/Sugar?action=launch&silent=true'}
    @{Name='Zenless Zone Zero';Target=$hoyo;Args='--game=nap_global'}
    @{Name='Minecraft Story Mode';Target='D:\Games\MinecraftStoryMode\Minecraft - Story Mode\GameApp.exe';Args=''}
)
if (Test-Path -LiteralPath $genshinGame -PathType Leaf) {
    $games += @{Name='Genshin Impact';Target=$hoyo;Args='--game=hk4e_global'}
}
$steamNames = @('Geometry Dash','Undertale','Castle Crashers','Goose Goose Duck','UNBEATABLE','Limbus Company','PEPPERED','The Sims 4','Rec Room','EVE Online','Apex Legends')
$manifests = Get-ChildItem @('C:\Program Files (x86)\Steam\steamapps','D:\SteamLibrary\steamapps','E:\SteamLibrary\steamapps') -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue
foreach ($name in $steamNames) {
    $match = $manifests | Where-Object {
        $manifestName = (Get-Content -LiteralPath $_.FullName -TotalCount 10 | Select-String '"name"\s+"(.+)"').Matches.Groups[1].Value
        $manifestName -eq $name -or ($name -eq 'The Sims 4' -and $manifestName -eq 'The Sims™ 4')
    } | Select-Object -First 1
    if ($match) {
        $id = [regex]::Match($match.Name, 'appmanifest_(\d+)\.acf').Groups[1].Value
        $games += @{Name=$name;Target=$steam;Args="-applaunch $id"}
    } else { Write-Warning "No Steam manifest found: $name" }
}
$games += @{Name='Roblox';Target='https://www.roblox.com/home';Args=''}

if ($Apply -and -not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an elevated PowerShell session to update the shared desktop.'
}
if ($Apply) { $shell = New-Object -ComObject WScript.Shell }
foreach ($game in $games) {
    $isUrl = $game.Target -match '^https://'
    $available = $isUrl -or (Test-Path -LiteralPath $game.Target -PathType Leaf)
    [pscustomobject]@{Game=$game.Name;Target=$game.Target;Available=$available;Destination=$commonDesktop}
    if (-not $Apply -or -not $available) { continue }
    $file = Join-Path $commonDesktop ($game.Name + $(if ($isUrl) {'.url'} else {'.lnk'}))
    if ($isUrl) { Set-Content -LiteralPath $file -Value "[InternetShortcut]`r`nURL=$($game.Target)" -Encoding Ascii }
    else {
        $link = $shell.CreateShortcut($file)
        $link.TargetPath = $game.Target
        $link.Arguments = $game.Args
        $link.WorkingDirectory = Split-Path -Parent $game.Target
        $link.Save()
    }
}
