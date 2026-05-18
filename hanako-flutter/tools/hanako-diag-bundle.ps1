<#
.SYNOPSIS
  幻宙 01 客户端故障排查 — 全量诊断打包。

.DESCRIPTION
  把客户端运行状态尽可能完整地收集成一个 zip，方便回传给开发者定位 bug。
  采集范围：

    HANA_HOME（默认 %APPDATA%\hanako）下：
      user/preferences.json
      models.json, auth.json
      agents/<id>/{config.yaml, identity.md, ishiki.md, session-meta.json}
      agents/<id>/sessions/*.jsonl           （全部 session 历史，含对话明文）
      agents/<id>/memory/                    （文件清单，不抓 facts.db 内容）
      agents/<id>/learned-skills/            （文件清单）
      agents/<id>/desk/                      （文件清单）
      desk/{cron-jobs.json, activities.json, heartbeat-config.json,
             jian-registry.json, cron-runs/ 清单}
      skills/                                （文件清单）
      logs/*.jsonl, logs/*.log               （全量原始日志）

    本机环境：
      system-info.txt                        OS / PowerShell / 时区 / 编码
      processes.json                         hanako / sidecar / QQ 相关进程快照
      sidecar-ping.json                      windows-ops sidecar HTTP ping 结果
      exec-command-probe.json                模拟 exec_command 实际执行行为
      qq-candidates.json                     常见路径探测 QQ 是否安装

    顶层：
      manifest.txt                           本次采集的所有动作和成败记录
      tree-listing.json                      整个 HANA_HOME 的文件树（仅 path+size+time）

  identity vault（私钥）由 Windows DPAPI 加密，本脚本不读取。
  对话明文存在 sessions/*.jsonl 中，将原样打包；发送前请自行确认敏感度。

.PARAMETER HanakoHome
  覆盖默认 HANA_HOME。优先级：参数 > $env:HANA_HOME > %APPDATA%\hanako。

.PARAMETER OutputDir
  zip 输出目录，默认桌面。

.EXAMPLE
  右键此 ps1，"使用 PowerShell 运行"。
  或：powershell -ExecutionPolicy Bypass -File .\hanako-diag-bundle.ps1
#>

[CmdletBinding()]
param(
    [string]$HanakoHome = '',
    [string]$OutputDir = ''
)

# 全脚本宽松错误处理（怕少不怕多，不能因为一处失败把整包丢掉）
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# 路径解析
# ---------------------------------------------------------------------------
function Resolve-HanaHome {
    param([string]$Override)
    if ($Override -and $Override.Trim().Length -gt 0) {
        return [System.IO.Path]::GetFullPath($Override)
    }
    if ($env:HANA_HOME -and $env:HANA_HOME.Trim().Length -gt 0) {
        return [System.IO.Path]::GetFullPath($env:HANA_HOME)
    }
    if ($env:APPDATA -and $env:APPDATA.Trim().Length -gt 0) {
        return Join-Path $env:APPDATA 'hanako'
    }
    if ($env:USERPROFILE -and $env:USERPROFILE.Trim().Length -gt 0) {
        return Join-Path $env:USERPROFILE 'AppData\Roaming\hanako'
    }
    throw 'Cannot resolve HANA_HOME. Pass -HanakoHome <path>.'
}

$hanaHome = Resolve-HanaHome -Override $HanakoHome
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "hanako-diag-$timestamp"
if (Test-Path -LiteralPath $workDir) {
    Remove-Item -LiteralPath $workDir -Recurse -Force
}
$null = New-Item -ItemType Directory -Path $workDir -Force

if (-not ($OutputDir -and $OutputDir.Trim().Length -gt 0)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop -and (Test-Path -LiteralPath $desktop -PathType Container)) {
        $OutputDir = $desktop
    } else {
        $OutputDir = (Get-Location).Path
    }
}

# ---------------------------------------------------------------------------
# 日志工具
# ---------------------------------------------------------------------------
$manifest = [System.Collections.Generic.List[string]]::new()
function Log([string]$Msg) {
    [void]$manifest.Add($Msg)
    Write-Host $Msg
}

function Copy-Safe {
    param([string]$Src, [string]$Dst, [string]$Label)
    if (-not (Test-Path -LiteralPath $Src)) {
        Log "[skip] $Label (not found)"
        return
    }
    try {
        $dstParent = Split-Path -Path $Dst -Parent
        if ($dstParent -and -not (Test-Path -LiteralPath $dstParent)) {
            $null = New-Item -ItemType Directory -Path $dstParent -Force
        }
        Copy-Item -LiteralPath $Src -Destination $Dst -Force -Recurse
        if (Test-Path -LiteralPath $Dst -PathType Leaf) {
            $size = (Get-Item -LiteralPath $Dst).Length
            Log "[ok]   $Label ($size bytes)"
        } else {
            $files = @(Get-ChildItem -LiteralPath $Dst -Recurse -File -ErrorAction SilentlyContinue)
            $total = ($files | Measure-Object -Property Length -Sum).Sum
            Log "[ok]   $Label ($($files.Count) files, $total bytes)"
        }
    } catch {
        Log "[fail] $Label : $($_.Exception.Message)"
    }
}

function Write-Json {
    param([Parameter(Mandatory)]$Obj, [Parameter(Mandatory)][string]$Path)
    try {
        $dstParent = Split-Path -Path $Path -Parent
        if ($dstParent -and -not (Test-Path -LiteralPath $dstParent)) {
            $null = New-Item -ItemType Directory -Path $dstParent -Force
        }
        $Obj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Log "[warn] write json failed for $Path : $($_.Exception.Message)"
    }
}

function List-Dir {
    param([string]$Src, [string]$Dst, [string]$Label)
    if (-not (Test-Path -LiteralPath $Src)) {
        Log "[skip] $Label (not found)"
        return
    }
    try {
        $entries = @(Get-ChildItem -LiteralPath $Src -Recurse -Force -ErrorAction SilentlyContinue |
            Select-Object @{
                Name = 'RelativePath'
                Expression = { $_.FullName.Substring($Src.Length).TrimStart('\','/') }
            }, Length, LastWriteTime, Mode)
        Write-Json -Obj $entries -Path $Dst
        Log "[ok]   $Label listing ($($entries.Count) entries)"
    } catch {
        Log "[fail] $Label listing : $($_.Exception.Message)"
    }
}

Log '============================================================'
Log "幻宙 01 诊断采集 — $timestamp"
Log "HANA_HOME : $hanaHome"
Log "WorkDir   : $workDir"
Log "OutputDir : $OutputDir"
Log "PSEdition : $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
Log '============================================================'

# ---------------------------------------------------------------------------
# 1. 系统信息
# ---------------------------------------------------------------------------
Log "`n=== 1. 系统信息 ==="
$sysInfo = [ordered]@{
    ComputerName = $env:COMPUTERNAME
    UserName     = $env:USERNAME
    UserProfile  = $env:USERPROFILE
    AppData      = $env:APPDATA
    LocalAppData = $env:LOCALAPPDATA
    HanaHomeEnv  = $env:HANA_HOME
    PSVersion    = $PSVersionTable.PSVersion.ToString()
    PSEdition    = $PSVersionTable.PSEdition
    OSVersion    = [System.Environment]::OSVersion.VersionString
    OSBuild      = [System.Environment]::OSVersion.Version.ToString()
    Is64BitOS    = [System.Environment]::Is64BitOperatingSystem
    Is64BitProc  = [System.Environment]::Is64BitProcess
    Culture      = (Get-Culture).Name
    UICulture    = (Get-UICulture).Name
    TimeZone     = (Get-TimeZone).Id
    CurrentTime  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
    PathFirst20  = @(($env:Path -split ';' | Where-Object { $_ } | Select-Object -First 20))
}
Write-Json -Obj $sysInfo -Path (Join-Path $workDir 'system-info.json')
Log "[ok]   system-info.json"

# ---------------------------------------------------------------------------
# 2. exec_command 实际执行行为模拟
#    复现 hanako-flutter 中 _runShellCommand 的调用：
#      Process.start('powershell.exe', ['-NoProfile', '-Command', <cmd>])
#    截图里第二轮 LLM 给出的 cmd 是：
#      powershell -NoProfile -Command "Start-Process QQ"
# ---------------------------------------------------------------------------
Log "`n=== 2. exec_command 行为模拟 ==="
$nestedCmd = 'powershell -NoProfile -Command "Start-Process QQ"'
$probe = [ordered]@{
    simulated_cmd = $nestedCmd
    note          = '模拟 _runShellCommand: powershell.exe -NoProfile -Command <cmd>，30s timeout'
    stdout        = $null
    stderr        = $null
    exit_code     = $null
    elapsed_ms    = $null
    timed_out     = $false
    error         = $null
}
$probeStdoutFile = Join-Path $workDir 'exec-command-probe.stdout.txt'
$probeStderrFile = Join-Path $workDir 'exec-command-probe.stderr.txt'
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    # PS 5.1 没有 ArgumentList，统一用 Arguments 字符串。-Command 后接单参数
    # （我们给的 cmd 本身可能包含双引号，外层再用单引号包裹）。
    # 强制子进程把 [Console]::OutputEncoding 切到 UTF-8 后再执行真正的命令，
    # 这样父进程也按 UTF-8 解码 stderr/stdout，避免中文 Windows 上的 GBK 乱码。
    $escaped = $nestedCmd.Replace('"', '\"')
    $wrapped = "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $escaped"
    $psi.Arguments = "-NoProfile -Command `"$wrapped`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit(30000)
    if (-not $exited) {
        try { $proc.Kill() } catch {}
        $probe.timed_out = $true
        $probe.exit_code = -1
    } else {
        $probe.exit_code = $proc.ExitCode
    }
    $stdoutText = $stdoutTask.Result
    $stderrText = $stderrTask.Result
    $sw.Stop()
    $probe.elapsed_ms = [int]$sw.ElapsedMilliseconds
    $stdoutText | Set-Content -LiteralPath $probeStdoutFile -Encoding UTF8
    $stderrText | Set-Content -LiteralPath $probeStderrFile -Encoding UTF8
    $probe.stdout = $stdoutText.Substring(0, [Math]::Min(2000, $stdoutText.Length))
    $probe.stderr = $stderrText.Substring(0, [Math]::Min(2000, $stderrText.Length))
} catch {
    $probe.error = $_.Exception.ToString()
}
Write-Json -Obj $probe -Path (Join-Path $workDir 'exec-command-probe.json')
Log "[ok]   exec_command probe : exit=$($probe.exit_code) elapsed=$($probe.elapsed_ms)ms timed_out=$($probe.timed_out)"

# QQ 路径探测
$qqProbe = [ordered]@{
    inPath     = $null
    candidates = @()
}
$qqCmd = Get-Command 'qq' -ErrorAction SilentlyContinue
if ($qqCmd) { $qqProbe.inPath = $qqCmd.Source }
$qqCandidatePaths = @(
    'C:\Program Files\Tencent\QQ\Bin\QQ.exe',
    'C:\Program Files (x86)\Tencent\QQ\Bin\QQ.exe',
    'C:\Program Files\Tencent\QQNT\QQ.exe',
    'C:\Program Files (x86)\Tencent\QQNT\QQ.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\Tencent\QQNT\QQ.exe'),
    'D:\Program Files\Tencent\QQNT\QQ.exe'
)
foreach ($cand in $qqCandidatePaths) {
    if (Test-Path -LiteralPath $cand) {
        $qqProbe.candidates += @{ path = $cand; exists = $true }
    }
}
Write-Json -Obj $qqProbe -Path (Join-Path $workDir 'qq-candidates.json')
Log "[ok]   qq-candidates.json (inPath=$($qqProbe.inPath -ne $null), hits=$($qqProbe.candidates.Count))"

# ---------------------------------------------------------------------------
# 3. windows-ops sidecar HTTP 探测
# ---------------------------------------------------------------------------
Log "`n=== 3. windows-ops sidecar HTTP 探测 ==="
$sidecarProbe = [ordered]@{
    pingUrl    = 'http://127.0.0.1:18086/ping'
    status     = $null
    bodyHead   = $null
    error      = $null
    altTried   = @()
}
$sidecarUrls = @(
    'http://127.0.0.1:18086/ping',
    'http://127.0.0.1:18086/health',
    'http://127.0.0.1:18086/capabilities',
    'http://localhost:18086/ping'
)
foreach ($url in $sidecarUrls) {
    try {
        $resp = Invoke-WebRequest -Uri $url -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
        $body = if ($resp.Content) { $resp.Content.Substring(0, [Math]::Min(4000, $resp.Content.Length)) } else { '' }
        $sidecarProbe.altTried += @{ url = $url; status = [int]$resp.StatusCode; body = $body }
        if (-not $sidecarProbe.status) {
            $sidecarProbe.pingUrl = $url
            $sidecarProbe.status = [int]$resp.StatusCode
            $sidecarProbe.bodyHead = $body
        }
    } catch {
        $sidecarProbe.altTried += @{ url = $url; error = $_.Exception.Message }
        if (-not $sidecarProbe.error) { $sidecarProbe.error = $_.Exception.Message }
    }
}
Write-Json -Obj $sidecarProbe -Path (Join-Path $workDir 'sidecar-ping.json')
Log "[ok]   sidecar-ping.json (status=$($sidecarProbe.status))"

# ---------------------------------------------------------------------------
# 4. 进程快照
# ---------------------------------------------------------------------------
Log "`n=== 4. 进程快照 ==="
try {
    $procs = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '(?i)hanako|phantasm|ph01|sidecar|qq' } |
        ForEach-Object {
            $startTime = $null
            try { $startTime = $_.StartTime.ToString('o') } catch {}
            [ordered]@{
                Id           = $_.Id
                Name         = $_.ProcessName
                Path         = $_.Path
                StartTime    = $startTime
                CPU          = $_.CPU
                WorkingSet64 = $_.WorkingSet64
            }
        })
    Write-Json -Obj $procs -Path (Join-Path $workDir 'processes.json')
    Log "[ok]   processes.json ($($procs.Count) matched)"
} catch {
    Log "[fail] processes : $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 5. HANA_HOME 是否存在
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $hanaHome)) {
    Log "`n[!!]  HANA_HOME does not exist: $hanaHome"
    Log "[!!]  跳过所有 hanako 文件采集，只打包系统/探测部分。"
} else {
    # -----------------------------------------------------------------------
    # 6. 全局配置 + 桌面状态
    # -----------------------------------------------------------------------
    Log "`n=== 6. 全局配置 ==="
    $homeDst = Join-Path $workDir 'home'
    Copy-Safe (Join-Path $hanaHome 'user\preferences.json')        (Join-Path $homeDst 'user\preferences.json')        'user/preferences.json'
    Copy-Safe (Join-Path $hanaHome 'models.json')                  (Join-Path $homeDst 'models.json')                  'models.json'
    Copy-Safe (Join-Path $hanaHome 'auth.json')                    (Join-Path $homeDst 'auth.json')                    'auth.json'
    Copy-Safe (Join-Path $hanaHome 'desk\heartbeat-config.json')   (Join-Path $homeDst 'desk\heartbeat-config.json')   'desk/heartbeat-config.json'
    Copy-Safe (Join-Path $hanaHome 'desk\cron-jobs.json')          (Join-Path $homeDst 'desk\cron-jobs.json')          'desk/cron-jobs.json'
    Copy-Safe (Join-Path $hanaHome 'desk\activities.json')         (Join-Path $homeDst 'desk\activities.json')         'desk/activities.json'
    Copy-Safe (Join-Path $hanaHome 'desk\jian-registry.json')      (Join-Path $homeDst 'desk\jian-registry.json')      'desk/jian-registry.json'
    List-Dir  (Join-Path $hanaHome 'desk\cron-runs')               (Join-Path $homeDst 'desk\cron-runs-listing.json')  'desk/cron-runs'
    List-Dir  (Join-Path $hanaHome 'desk\activity')                (Join-Path $homeDst 'desk\activity-listing.json')   'desk/activity'

    # -----------------------------------------------------------------------
    # 7. 日志（全量）
    # -----------------------------------------------------------------------
    Log "`n=== 7. logs 全量 ==="
    $logsSrc = Join-Path $hanaHome 'logs'
    if (Test-Path -LiteralPath $logsSrc) {
        Copy-Safe $logsSrc (Join-Path $homeDst 'logs') 'logs/'
    } else {
        Log "[skip] logs (not found)"
    }

    # -----------------------------------------------------------------------
    # 8. agents
    # -----------------------------------------------------------------------
    Log "`n=== 8. agents ==="
    $agentsSrc = Join-Path $hanaHome 'agents'
    if (Test-Path -LiteralPath $agentsSrc) {
        foreach ($agentDir in @(Get-ChildItem -LiteralPath $agentsSrc -Directory -ErrorAction SilentlyContinue)) {
            $aid = $agentDir.Name
            $aSrc = $agentDir.FullName
            $aDst = Join-Path $homeDst "agents\$aid"
            Log "-- agent $aid --"

            Copy-Safe (Join-Path $aSrc 'config.yaml')        (Join-Path $aDst 'config.yaml')        "agents/$aid/config.yaml"
            Copy-Safe (Join-Path $aSrc 'identity.md')        (Join-Path $aDst 'identity.md')        "agents/$aid/identity.md"
            Copy-Safe (Join-Path $aSrc 'ishiki.md')          (Join-Path $aDst 'ishiki.md')          "agents/$aid/ishiki.md"
            # avatars 目录（可能含头像图）整体拷
            Copy-Safe (Join-Path $aSrc 'avatars')            (Join-Path $aDst 'avatars')            "agents/$aid/avatars/"

            # sessions 全量
            $sSrc = Join-Path $aSrc 'sessions'
            if (Test-Path -LiteralPath $sSrc) {
                Copy-Safe $sSrc (Join-Path $aDst 'sessions') "agents/$aid/sessions/"
            } else {
                Log "[skip] agents/$aid/sessions (not found)"
            }

            # memory 文件清单（facts.db 较大不抓内容；如需要可手动拿）
            List-Dir (Join-Path $aSrc 'memory')          (Join-Path $aDst 'memory-listing.json')          "agents/$aid/memory"
            List-Dir (Join-Path $aSrc 'learned-skills')  (Join-Path $aDst 'learned-skills-listing.json')  "agents/$aid/learned-skills"
            List-Dir (Join-Path $aSrc 'desk')            (Join-Path $aDst 'desk-listing.json')            "agents/$aid/desk"
        }
    } else {
        Log "[skip] agents (not found)"
    }

    # -----------------------------------------------------------------------
    # 9. skills 全局
    # -----------------------------------------------------------------------
    Log "`n=== 9. 全局 skills 清单 ==="
    List-Dir (Join-Path $hanaHome 'skills') (Join-Path $homeDst 'skills-listing.json') 'skills/'

    # -----------------------------------------------------------------------
    # 10. HANA_HOME 整体目录树（含相对路径 / 大小 / 时间 / 模式）
    # -----------------------------------------------------------------------
    Log "`n=== 10. HANA_HOME 整体目录树 ==="
    try {
        $treeEntries = @(Get-ChildItem -LiteralPath $hanaHome -Recurse -Force -ErrorAction SilentlyContinue |
            Select-Object @{
                Name = 'RelativePath'
                Expression = { $_.FullName.Substring($hanaHome.Length).TrimStart('\','/') }
            }, Length, LastWriteTime, Mode)
        Write-Json -Obj $treeEntries -Path (Join-Path $workDir 'tree-listing.json')
        Log "[ok]   tree-listing.json ($($treeEntries.Count) entries)"
    } catch {
        Log "[fail] tree-listing : $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 11. 写 manifest 并打包
# ---------------------------------------------------------------------------
$manifest -join "`r`n" | Set-Content -LiteralPath (Join-Path $workDir 'manifest.txt') -Encoding UTF8

$zipPath = Join-Path $OutputDir "hanako-diag-$timestamp.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Write-Host ''
Write-Host "正在打包 → $zipPath"
try {
    Compress-Archive -Path (Join-Path $workDir '*') -DestinationPath $zipPath -Force -ErrorAction Stop
} catch {
    Write-Host "Compress-Archive 失败，改用 ZipFile API 兜底：$($_.Exception.Message)"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $workDir, $zipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )
}

$zipSizeMB = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)

Write-Host ''
Write-Host '============================================================'
Write-Host "  完成。诊断包: $zipPath"
Write-Host "  大小: $zipSizeMB MB"
Write-Host '  请将该 zip 文件回传给开发者。'
Write-Host '  注意：包内含历史对话明文（不含私钥），发送前请自查敏感度。'
Write-Host '============================================================'
Write-Host ''
Write-Host "工作目录已保留供查看：$workDir"
Write-Host '(全部完成后可手动删除)'
Write-Host ''
Read-Host '按 Enter 关闭本窗口'
