param(
    [string]$Version = "dev",
    [string]$Goos = "linux",
    [string]$Goarch = "amd64",
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $PSCommandPath
$RootDir = Split-Path -Parent $ScriptDir
$PackageDir = Join-Path $RootDir "deployment-package"
$BinDir = Join-Path $PackageDir "bin"
$ReleaseDir = Join-Path $RootDir "release"
$BinaryPath = Join-Path $BinDir "experience-dht"
$ArchivePath = Join-Path $ReleaseDir "experience-dht-deployment-package-$Version-$Goos-$Goarch.zip"

New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
New-Item -ItemType Directory -Force -Path $ReleaseDir | Out-Null

Push-Location $RootDir
try {
    if (-not $SkipTests) {
        go test ./...
    }

    $oldCgo = $env:CGO_ENABLED
    $oldGoos = $env:GOOS
    $oldGoarch = $env:GOARCH
    try {
        $env:CGO_ENABLED = "0"
        $env:GOOS = $Goos
        $env:GOARCH = $Goarch
        go build -ldflags "-s -w" -o $BinaryPath ./cmd/experience-dht
    }
    finally {
        $env:CGO_ENABLED = $oldCgo
        $env:GOOS = $oldGoos
        $env:GOARCH = $oldGoarch
    }

    if (Test-Path -LiteralPath $ArchivePath) {
        Remove-Item -LiteralPath $ArchivePath
    }
    $packageItems = Get-ChildItem -LiteralPath $PackageDir -Force |
        Where-Object {
            $_.Name -ne "data" -and
            $_.Extension -ne ".zip" -and
            $_.Extension -ne ".gz"
        } |
        ForEach-Object { $_.FullName }
    Compress-Archive -Path $packageItems -DestinationPath $ArchivePath
    Write-Host "[package] wrote $ArchivePath"
}
finally {
    Pop-Location
}
