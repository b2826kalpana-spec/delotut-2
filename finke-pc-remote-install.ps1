$ErrorActionPreference = 'Stop'

function Get-GhPath {
    $cmd = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
    if (Test-Path $candidate) { return $candidate }
    return $null
}

Write-Host '=== FINKE PC Remote installer ==='

$gh = Get-GhPath
if (-not $gh) {
    Write-Host 'Installing GitHub CLI...'
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget is not available on this PC.'
    }
    & winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI installation failed.' }
    $gh = Join-Path $env:ProgramFiles 'GitHub CLI\gh.exe'
}

& $gh auth status -h github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'One authorization is required. Your browser will open GitHub.'
    & $gh auth login --hostname github.com --web --git-protocol https
    if ($LASTEXITCODE -ne 0) { throw 'GitHub authorization failed.' }
}

$login = (& $gh api user --jq '.login' 2>$null | Out-String).Trim()
if ($login -ne 'b2826kalpana-spec') {
    throw "Wrong GitHub account: $login. Expected b2826kalpana-spec."
}

$tmp = Join-Path $env:TEMP 'finke-pc-remote-bootstrap.ps1'
$raw = & $gh api 'repos/b2826kalpana-spec/Svoi/contents/tools/finke-pc-remote/bootstrap.ps1' -H 'Accept: application/vnd.github.raw+json' 2>&1
if ($LASTEXITCODE -ne 0) { throw ('Could not download private bootstrap: ' + ($raw | Out-String)) }
$raw | Set-Content -Path $tmp -Encoding UTF8

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp
$code = $LASTEXITCODE
Remove-Item $tmp -Force -ErrorAction SilentlyContinue
exit $code
