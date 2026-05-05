# 清理本地构建 / 依赖缓存，便于压缩上传 PH01 正式部署目录。
# 不删除源码、配置种子、证书种子或 data/production。

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Resolve-Path (Join-Path $scriptDir '..\..\..')

$relativeTargets = @(
    'ph01-ai-gateway\.cache',
    'ph01-ai-gateway\.npm-cache',
    'ph01-ai-gateway\bin',
    'ph01-ai-gateway\web\default\node_modules',
    'ph01-ai-gateway\web\classic\node_modules',
    'ph01-ai-gateway\web\default\dist',
    'ph01-ai-gateway\web\classic\dist',
    'ph01-backend\bin',
    'ph01-backend\data',
    'ph01-backend\auth-gateway.exe',
    'ph01-experience-hub\bin',
    'ph01-experience-hub\data'
)

foreach ($relative in $relativeTargets) {
    $target = Join-Path $rootDir $relative
    if (-not (Test-Path -LiteralPath $target)) {
        continue
    }

    $resolved = Resolve-Path -LiteralPath $target
    if (-not $resolved.Path.StartsWith($rootDir.Path, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refuse to delete outside workspace: $($resolved.Path)"
    }

    Write-Host "[clean] $relative"
    Remove-Item -LiteralPath $resolved.Path -Recurse -Force
}

Write-Host "[clean] done"
