#requires -version 5
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (Test-Path 'data\.auth.pid') {
    $pid = Get-Content 'data\.auth.pid'
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    Write-Host "[stop] auth-center PID=$pid"
    Remove-Item 'data\.auth.pid' -ErrorAction SilentlyContinue
}

if (Test-Path 'data\.ai.pid') {
    $pid = Get-Content 'data\.ai.pid'
    Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
    Write-Host "[stop] legacy ai-gateway PID=$pid"
    Remove-Item 'data\.ai.pid' -ErrorAction SilentlyContinue
}
