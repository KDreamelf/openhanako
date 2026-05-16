param(
    [string]$HanaHome = "",
    [string]$OutputDir = "",
    [string]$AgentId = "",
    [switch]$KeepStage
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Resolve-HanaHome {
    param([string]$Override)

    if ($Override -and $Override.Trim().Length -gt 0) {
        return [System.IO.Path]::GetFullPath($Override)
    }

    if ($env:HANA_HOME -and $env:HANA_HOME.Trim().Length -gt 0) {
        return [System.IO.Path]::GetFullPath($env:HANA_HOME)
    }

    if ($env:APPDATA -and $env:APPDATA.Trim().Length -gt 0) {
        return (Join-Path $env:APPDATA "hanako")
    }

    if ($env:USERPROFILE -and $env:USERPROFILE.Trim().Length -gt 0) {
        return (Join-Path $env:USERPROFILE "AppData\Roaming\hanako")
    }

    throw "Cannot resolve HANA_HOME. Please pass -HanaHome <path>."
}

function Copy-DirectoryIfExists {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$Label,
        [System.Collections.ArrayList]$Copied
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return
    }

    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    [void]$Copied.Add($Label)
}

$sourceRoot = Resolve-HanaHome -Override $HanaHome
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    Write-Error "Hanako data directory was not found: $sourceRoot"
    exit 1
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "hanako-log-export-$stamp"
if (Test-Path -LiteralPath $stageRoot) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

$copied = New-Object System.Collections.ArrayList

$logsSource = Join-Path $sourceRoot "logs"
$logsDest = Join-Path $stageRoot "logs"
Copy-DirectoryIfExists -Source $logsSource -Destination $logsDest -Label "logs" -Copied $copied

$agentsSource = Join-Path $sourceRoot "agents"
$agentsDest = Join-Path $stageRoot "agents"

if (Test-Path -LiteralPath $agentsSource -PathType Container) {
    $agentDirs = @()
    if ($AgentId -and $AgentId.Trim().Length -gt 0) {
        $candidate = Join-Path $agentsSource $AgentId
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $agentDirs = @(Get-Item -LiteralPath $candidate)
        } else {
            Write-Warning "Agent directory was not found: $candidate"
        }
    } else {
        $agentDirs = @(Get-ChildItem -LiteralPath $agentsSource -Directory -ErrorAction SilentlyContinue)
    }

    foreach ($agentDir in $agentDirs) {
        $sessionsSource = Join-Path $agentDir.FullName "sessions"
        $sessionsDest = Join-Path (Join-Path $agentsDest $agentDir.Name) "sessions"
        Copy-DirectoryIfExists `
            -Source $sessionsSource `
            -Destination $sessionsDest `
            -Label ("agents/" + $agentDir.Name + "/sessions") `
            -Copied $copied
    }
}

$payloadFileCount = (Get-ChildItem -LiteralPath $stageRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
$manifestPath = Join-Path $stageRoot "manifest.json"
$manifest = [ordered]@{
    exportedAt = (Get-Date).ToString("o")
    sourceRoot = $sourceRoot
    agentId = $(if ($AgentId -and $AgentId.Trim().Length -gt 0) { $AgentId } else { $null })
    copiedPaths = @($copied)
    payloadFileCount = $payloadFileCount
    note = "This archive contains logs and agent session records only. It intentionally excludes identity, keys, config, experience data, cache, and browser storage."
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

if (-not ($OutputDir -and $OutputDir.Trim().Length -gt 0)) {
    $desktop = [Environment]::GetFolderPath("Desktop")
    if ($desktop -and (Test-Path -LiteralPath $desktop -PathType Container)) {
        $OutputDir = $desktop
    } else {
        $OutputDir = (Get-Location).Path
    }
}

if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$zipPath = Join-Path $OutputDir "hanako-log-export-$stamp.zip"
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Compress-Archive -Path (Join-Path $stageRoot "*") -DestinationPath $zipPath -Force

if (-not $KeepStage) {
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}

if ($payloadFileCount -eq 0) {
    Write-Warning "No log or session payload files were found. The archive only contains manifest.json."
}

Write-Host "Hanako log export complete."
Write-Host "Archive: $zipPath"
Write-Host "Source:  $sourceRoot"
Write-Host "Payload files: $payloadFileCount"
if ($KeepStage) {
    Write-Host "Stage:   $stageRoot"
}
