#requires -version 5
# Windows PowerShell 启动 PH01 认证中心。

[CmdletBinding()]
param(
    [switch]$Rebuild,
    [string]$Config = "config.hcl"
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

New-Item -ItemType Directory -Force -Path data, data\logs, bin | Out-Null

if (-not (Test-Path $Config)) {
    Copy-Item "config.hcl.example" $Config
    Write-Host "[init] 已从 config.hcl.example 生成 $Config"
    Write-Host "[init] 请先填写 PostgreSQL DSN、Redis URL 和 admin token，再重新运行。"
    exit 1
}

$configText = Get-Content -Raw $Config
if ($configText -match "CHANGE_ME") {
    Write-Host "[error] $Config 中仍包含 CHANGE_ME，占位配置不能启动服务。"
    exit 1
}

if ($Rebuild -or -not (Test-Path 'bin\auth-gateway.exe')) {
    Write-Host "[build] 编译中..."
    & go build -o bin\auth-gateway.exe .\cmd\auth-gateway
}

Write-Host "[start] auth-center"
$auth = Start-Process -FilePath '.\bin\auth-gateway.exe' `
    -ArgumentList @("-config", $Config) `
    -RedirectStandardOutput 'data\logs\auth.log' `
    -RedirectStandardError 'data\logs\auth.err.log' `
    -WindowStyle Hidden `
    -PassThru
$auth.Id | Out-File 'data\.auth.pid' -Encoding ascii

Write-Host ""
Write-Host "================================================"
Write-Host "服务已启动："
Write-Host "  auth-center PID=$($auth.Id)    http://localhost:8080"
Write-Host ""
Write-Host "管理后台："
Write-Host "  http://localhost:8080/admin-ui/auth.html"
Write-Host ""
Write-Host "配置文件：$Config"
Write-Host "停止：.\scripts\stop-all.ps1"
Write-Host "================================================"
