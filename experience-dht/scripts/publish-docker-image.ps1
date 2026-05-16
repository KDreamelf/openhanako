param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [string]$Repository = "dreamelf6174/experience-dht",
    [switch]$NoPush
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$RootDir = Split-Path -Parent $ScriptDir
$PackageDir = Join-Path $RootDir "deployment-package"
$BinaryPath = Join-Path $PackageDir "bin\experience-dht"
$AlpineMirror = if ($env:EXPERIENCE_DHT_ALPINE_MIRROR) {
    $env:EXPERIENCE_DHT_ALPINE_MIRROR
} else {
    "http://mirrors.aliyun.com/alpine"
}

if (-not (Test-Path -LiteralPath $BinaryPath)) {
    throw "missing prebuilt binary: $BinaryPath. Run .\scripts\build-deployment-package.ps1 -Version $Version first."
}

docker build `
    --build-arg "ALPINE_MIRROR=$AlpineMirror" `
    -t "${Repository}:${Version}" `
    -t "${Repository}:latest" `
    $PackageDir
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

if (-not $NoPush) {
    docker push "${Repository}:${Version}"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    docker push "${Repository}:latest"
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host "[docker] image ready: ${Repository}:${Version}"
