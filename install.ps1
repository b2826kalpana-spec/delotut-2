param(
    [string]$Repository = 'b2826kalpana-spec/Svoi',
    [int]$Issue = 10,
    [string]$AllowedAuthor = 'b2826kalpana-spec',
    [string]$ServerHost = '37.18.102.247',
    [string]$ServerUser = 'delotut',
    [string]$IdentityFile = '%USERPROFILE%\.ssh\delo_tut_cloud',
    [switch]$NoAutostart
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Ok([string]$Text) { Write-Host "[OK] $Text" -ForegroundColor Green }

if ($env:OS -ne 'Windows_NT') { throw 'FINKE PC Remote installer is for Windows.' }

$baseDir = Join-Path $env:LOCALAPPDATA 'FinkePcRemote'
New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
$agentPath = Join-Path $baseDir 'agent.ps1'
$configPath = Join-Path $baseDir 'config.json'
$stopPath = Join-Path $baseDir 'STOP'
$statusPath = Join-Path $baseDir 'status.json'
Remove-Item $stopPath -Force -ErrorAction SilentlyContinue

Step 'Checking GitHub CLI'
if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Host 'GitHub CLI is missing. Installing it with winget...'
        & winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
        if ($LASTEXITCODE -ne 0) { throw 'winget could not install GitHub CLI.' }
        $machineGh = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
        if (Test-Path $machineGh) { $env:PATH = "$env:ProgramFiles\GitHub CLI;$env:PATH" }
    } else {
        throw 'GitHub CLI is not installed and winget is unavailable. Install GitHub CLI, then rerun this installer.'
    }
}
if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) { throw 'gh.exe is still unavailable after installation.' }
Ok 'GitHub CLI available'

Step 'Checking GitHub authorization'
& gh auth status -h github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'A browser window will open. Authorize GitHub once; the installer will continue automatically.' -ForegroundColor Yellow
    & gh auth login -h github.com -p https -w
    if ($LASTEXITCODE -ne 0) { throw 'GitHub authorization was not completed.' }
}
& gh api "repos/$Repository/issues/$Issue" *> $null
if ($LASTEXITCODE -ne 0) { throw "Cannot access $Repository issue #$Issue with the current GitHub login." }
Ok "Authorized for $Repository issue #$Issue"

Step 'Checking Windows OpenSSH'
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
    throw 'Windows OpenSSH Client is missing. Install the Windows optional feature OpenSSH Client, then rerun.'
}
$expandedIdentity = [Environment]::ExpandEnvironmentVariables($IdentityFile)
if (-not (Test-Path $expandedIdentity)) { throw "SSH key not found: $expandedIdentity" }
Ok "SSH key found locally: $expandedIdentity"

Step 'Downloading FINKE PC Remote agent'
$agentUrl = 'https://raw.githubusercontent.com/b2826kalpana-spec/delotut-2/main/agent.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $agentUrl -OutFile $agentPath
if (-not (Test-Path $agentPath)) { throw 'Agent download failed.' }
Ok "Agent installed to $agentPath"

Step 'Writing local configuration'
$config = [ordered]@{
    repository = $Repository
    issue = $Issue
    allowedAuthor = $AllowedAuthor
    pollSeconds = 2
    allowDangerous = $false
    server = [ordered]@{
        host = $ServerHost
        user = $ServerUser
        identityFile = $IdentityFile
    }
}
$config | ConvertTo-Json -Depth 5 | Set-Content -Path $configPath -Encoding UTF8
Ok 'Local config created (dangerous actions disabled by default)'

Step 'Testing SSH path to Cloud.ru'
$probe = & ssh.exe -i $expandedIdentity -o BatchMode=yes -o ConnectTimeout=10 "$ServerUser@$ServerHost" 'printf FINKE_SERVER_OK' 2>&1
if ($LASTEXITCODE -eq 0 -and ($probe -join "`n") -match 'FINKE_SERVER_OK') {
    Ok 'Cloud.ru SSH is ready'
} else {
    Write-Host '[WARN] Cloud.ru SSH probe failed. PC control can still start; server control will show NOT READY.' -ForegroundColor Yellow
    Write-Host ($probe -join "`n")
}

$desktop = [Environment]::GetFolderPath('Desktop')
$startCmd = Join-Path $desktop 'FINKE PC REMOTE.cmd'
$stopCmd = Join-Path $desktop 'FINKE PC REMOTE STOP.cmd'
$statusCmd = Join-Path $desktop 'FINKE PC REMOTE STATUS.cmd'

@"
@echo off
if exist "$stopPath" del /q "$stopPath"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "$agentPath" -ConfigPath "$configPath"
pause
"@ | Set-Content -Path $startCmd -Encoding ASCII

@"
@echo off
if not exist "$baseDir" mkdir "$baseDir"
echo stop>"$stopPath"
echo Stop signal created. Agent will exit after the current poll cycle.
timeout /t 3 /nobreak >nul
"@ | Set-Content -Path $stopCmd -Encoding ASCII

@"
@echo off
if exist "$statusPath" (
  type "$statusPath"
) else (
  echo Agent status file not found.
)
pause
"@ | Set-Content -Path $statusCmd -Encoding ASCII

if (-not $NoAutostart) {
    Step 'Enabling user-level autostart'
    $startup = [Environment]::GetFolderPath('Startup')
    $autoCmd = Join-Path $startup 'FinkePcRemote.cmd'
    @"
@echo off
if exist "$stopPath" del /q "$stopPath"
start "FINKE PC REMOTE" /min powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$agentPath" -ConfigPath "$configPath"
"@ | Set-Content -Path $autoCmd -Encoding ASCII
    Ok 'Autostart enabled for this Windows user'
}

Step 'Starting agent now'
$existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*FinkePcRemote*agent.ps1*" }
if (-not $existing) {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$agentPath,'-ConfigPath',$configPath)
}

$deadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadline -and -not (Test-Path $statusPath)) { Start-Sleep -Milliseconds 500 }
if (Test-Path $statusPath) {
    $status = Get-Content -Raw $statusPath | ConvertFrom-Json
    Ok "Agent ONLINE on $($status.hostname) as $($status.user); serverReady=$($status.serverReady); pid=$($status.pid)"
} else {
    Write-Host '[WARN] Agent did not create status.json within 25 seconds. Check:' -ForegroundColor Yellow
    Write-Host "  $baseDir\agent.log"
}

Write-Host "`nFINKE PC REMOTE installation finished." -ForegroundColor Green
Write-Host "Desktop launchers:"
Write-Host "  $startCmd"
Write-Host "  $stopCmd"
Write-Host "  $statusCmd"
Write-Host "`nKeep GitHub authentication active. No private SSH key was uploaded or copied." -ForegroundColor DarkGray
