param(
    [string]$ConfigPath = "$env:LOCALAPPDATA\FinkePcRemote\config.json"
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Log {
    param([string]$Message)
    $dir = Split-Path -Parent $ConfigPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = "$(Get-Date -Format o) $Message"
    Add-Content -Path (Join-Path $dir 'agent.log') -Value $line -Encoding UTF8
}

function Invoke-ProcessCaptured {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [string]$Arguments = '',
        [int]$TimeoutSeconds = 60,
        [string]$WorkingDirectory = $env:USERPROFILE
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

    $p = [System.Diagnostics.Process]::new()
    $p.StartInfo = $psi
    $sw = [Diagnostics.Stopwatch]::StartNew()
    [void]$p.Start()
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    $finished = $p.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
    if (-not $finished) {
        try { $p.Kill($true) } catch { try { $p.Kill() } catch {} }
        try { $p.WaitForExit(5000) | Out-Null } catch {}
    }
    $sw.Stop()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [pscustomobject]@{
        ExitCode = if ($finished) { $p.ExitCode } else { 124 }
        TimedOut = -not $finished
        StdOut = $stdout
        StdErr = $stderr
        DurationMs = [int]$sw.ElapsedMilliseconds
    }
}

function Limit-Text {
    param([string]$Text, [int]$MaxChars = 18000)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $MaxChars) { return $Text }
    return $Text.Substring(0, $MaxChars) + "`n... [truncated by FINKE PC REMOTE]"
}

function Test-DangerousCommand {
    param([string]$Command)
    $patterns = @(
        '(?i)\bRemove-Item\b.*\b-Recurse\b',
        '(?i)\b(rm|rmdir|del)\b.*(?:/s|-rf|-r\b)',
        '(?i)\b(format|diskpart|Clear-Disk|Initialize-Disk|Remove-Partition|mkfs|fdisk)\b',
        '(?i)\b(shutdown|Restart-Computer|Stop-Computer|reboot|poweroff)\b',
        '(?i)\b(netsh\s+advfirewall\s+set\s+.*state\s+off)\b',
        '(?i)\b(reg\s+delete|Remove-LocalUser|net\s+user\s+.*\/delete)\b',
        '(?i)(\.ssh[\\/].*(id_rsa|id_ed25519|delo_tut_cloud))(?!\.pub)',
        '(?i)\b(Get-ChildItem\s+Env:|set\s*$|env\s*$|printenv\s*$)'
    )
    foreach ($pattern in $patterns) {
        if ($Command -match $pattern) { return $true }
    }
    return $false
}

function Post-Comment {
    param([string]$Repository, [int]$Issue, [string]$Body)
    $tmp = Join-Path $env:TEMP ("finke-comment-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        @{ body = $Body } | ConvertTo-Json -Compress | Set-Content -Path $tmp -Encoding UTF8
        $r = Invoke-ProcessCaptured -FileName 'gh.exe' -Arguments "api -X POST repos/$Repository/issues/$Issue/comments --input `"$tmp`"" -TimeoutSeconds 30
        if ($r.ExitCode -ne 0) { throw "GitHub comment failed: $($r.StdErr)" }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PCCommand {
    param([string]$Command, [int]$TimeoutSeconds)
    $bytes = [Text.Encoding]::Unicode.GetBytes($Command)
    $encoded = [Convert]::ToBase64String($bytes)
    Invoke-ProcessCaptured -FileName 'powershell.exe' -Arguments "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded" -TimeoutSeconds $TimeoutSeconds
}

function Invoke-ServerCommand {
    param($Config, [string]$Command, [int]$TimeoutSeconds)
    $identity = [Environment]::ExpandEnvironmentVariables($Config.server.identityFile)
    if (-not (Test-Path $identity)) { throw "SSH identity not found: $identity" }
    $utf8 = [Text.Encoding]::UTF8.GetBytes($Command)
    $b64 = [Convert]::ToBase64String($utf8)
    $remote = "echo $b64 | base64 -d | bash"
    $dest = "$($Config.server.user)@$($Config.server.host)"
    $args = "-i `"$identity`" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 $dest `"$remote`""
    Invoke-ProcessCaptured -FileName 'ssh.exe' -Arguments $args -TimeoutSeconds $TimeoutSeconds
}

function Parse-CommandComment {
    param([string]$Body)
    if (-not $Body.StartsWith('FINKE_CMD_V1')) { return $null }
    $parts = $Body -split "`r?`n", 2
    if ($parts.Count -lt 2) { return $null }
    try {
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1].Trim()))
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }
$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json
$baseDir = Split-Path -Parent $ConfigPath
$statePath = Join-Path $baseDir 'state.json'
$stopPath = Join-Path $baseDir 'STOP'
$statusPath = Join-Path $baseDir 'status.json'

if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) { throw 'gh.exe not found. Re-run installer.' }
if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) { throw 'ssh.exe not found. Install Windows OpenSSH Client.' }

$auth = Invoke-ProcessCaptured -FileName 'gh.exe' -Arguments 'auth status -h github.com' -TimeoutSeconds 20
if ($auth.ExitCode -ne 0) { throw 'GitHub CLI is not authenticated. Run: gh auth login -h github.com --web' }

$lastCommentId = 0L
if (Test-Path $statePath) {
    try { $lastCommentId = [int64]((Get-Content -Raw $statePath | ConvertFrom-Json).lastCommentId) } catch {}
}

$serverReady = $false
try {
    $probe = Invoke-ServerCommand -Config $config -Command 'printf FINKE_SERVER_OK' -TimeoutSeconds 15
    $serverReady = ($probe.ExitCode -eq 0 -and $probe.StdOut -match 'FINKE_SERVER_OK')
} catch { Write-Log "Server probe failed: $($_.Exception.Message)" }

$status = [ordered]@{
    startedAt = (Get-Date).ToString('o')
    hostname = $env:COMPUTERNAME
    user = $env:USERNAME
    pid = $PID
    repository = $config.repository
    issue = $config.issue
    serverReady = $serverReady
    allowDangerous = [bool]$config.allowDangerous
}
$status | ConvertTo-Json | Set-Content -Path $statusPath -Encoding UTF8

try {
    $readyBody = "FINKE_STATUS_V1`nPC agent ONLINE`nHost: $env:COMPUTERNAME`nUser: $env:USERNAME`nServer SSH: $(if($serverReady){'OK'}else{'NOT READY'})`nPID: $PID"
    Post-Comment -Repository $config.repository -Issue $config.issue -Body $readyBody
} catch { Write-Log "Could not post ready status: $($_.Exception.Message)" }

Write-Log "Agent online. repo=$($config.repository) issue=$($config.issue) serverReady=$serverReady"

while (-not (Test-Path $stopPath)) {
    try {
        $endpoint = "repos/$($config.repository)/issues/$($config.issue)/comments?per_page=100"
        $res = Invoke-ProcessCaptured -FileName 'gh.exe' -Arguments "api $endpoint" -TimeoutSeconds 30
        if ($res.ExitCode -ne 0) { throw "GitHub poll failed: $($res.StdErr)" }
        $comments = @($res.StdOut | ConvertFrom-Json)
        $comments = $comments | Sort-Object id

        foreach ($comment in $comments) {
            $cid = [int64]$comment.id
            if ($cid -le $lastCommentId) { continue }
            $lastCommentId = $cid
            @{ lastCommentId = $lastCommentId } | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8

            if ($comment.user.login -ne $config.allowedAuthor) { continue }
            $cmd = Parse-CommandComment -Body ([string]$comment.body)
            if ($null -eq $cmd) { continue }
            if (-not $cmd.id -or -not $cmd.command) { continue }

            $timeout = 60
            if ($cmd.timeoutSeconds) { $timeout = [Math]::Min([Math]::Max([int]$cmd.timeoutSeconds, 1), 600) }
            $target = if ($cmd.target) { [string]$cmd.target } else { 'pc' }
            $dangerousDetected = Test-DangerousCommand -Command ([string]$cmd.command)
            $dangerousRequested = ($cmd.dangerous -eq $true)
            $allowed = (-not $dangerousDetected) -or ($dangerousRequested -and [bool]$config.allowDangerous)

            if (-not $allowed) {
                $body = "FINKE_RESULT_V1`nID: $($cmd.id)`nTarget: $target`nStatus: BLOCKED`nReason: command matched local dangerous/secret guardrail. To run it, both dangerous:true and local allowDangerous:true are required."
                Post-Comment -Repository $config.repository -Issue $config.issue -Body $body
                continue
            }

            Write-Log "Executing id=$($cmd.id) target=$target timeout=$timeout"
            try {
                if ($target -eq 'server') {
                    $run = Invoke-ServerCommand -Config $config -Command ([string]$cmd.command) -TimeoutSeconds $timeout
                } elseif ($target -eq 'pc') {
                    $run = Invoke-PCCommand -Command ([string]$cmd.command) -TimeoutSeconds $timeout
                } else {
                    throw "Unknown target '$target'"
                }
                $combined = ''
                if ($run.StdOut) { $combined += $run.StdOut }
                if ($run.StdErr) { $combined += "`n[stderr]`n$($run.StdErr)" }
                $combined = Limit-Text $combined
                $statusText = if ($run.TimedOut) { 'TIMEOUT' } elseif ($run.ExitCode -eq 0) { 'SUCCESS' } else { 'FAILED' }
                $body = "FINKE_RESULT_V1`nID: $($cmd.id)`nTarget: $target`nStatus: $statusText`nExitCode: $($run.ExitCode)`nDurationMs: $($run.DurationMs)`n```text`n$combined`n```"
                Post-Comment -Repository $config.repository -Issue $config.issue -Body $body
            } catch {
                $msg = Limit-Text $_.Exception.Message 4000
                $body = "FINKE_RESULT_V1`nID: $($cmd.id)`nTarget: $target`nStatus: ERROR`n```text`n$msg`n```"
                Post-Comment -Repository $config.repository -Issue $config.issue -Body $body
            }
        }
    } catch {
        Write-Log "Loop error: $($_.Exception.Message)"
    }
    Start-Sleep -Seconds ([Math]::Max(1, [int]$config.pollSeconds))
}

Write-Log 'STOP file detected. Agent shutting down.'
try { Post-Comment -Repository $config.repository -Issue $config.issue -Body "FINKE_STATUS_V1`nPC agent OFFLINE`nHost: $env:COMPUTERNAME" } catch {}
