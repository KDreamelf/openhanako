param(
    [ValidateSet("init", "up", "pull", "build", "down", "logs", "ps", "reset")]
    [string]$Mode = "up"
)

$ErrorActionPreference = "Stop"

$PackageDir = Split-Path -Parent $PSCommandPath

if (-not $env:EXPERIENCE_DHT_DATA_DIR) {
    $env:EXPERIENCE_DHT_DATA_DIR = Join-Path $PackageDir "data"
}
if (-not $env:EXPERIENCE_DHT_PROJECT) {
    $env:EXPERIENCE_DHT_PROJECT = "experience-dht"
}
if (-not $env:EXPERIENCE_DHT_IMAGE) {
    $env:EXPERIENCE_DHT_IMAGE = "dreamelf6174/experience-dht:latest"
}

function Get-ComposeCommand {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        docker compose version *> $null
        if ($LASTEXITCODE -eq 0) {
            return @("docker", "compose")
        }
    }

    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        docker-compose version *> $null
        if ($LASTEXITCODE -eq 0) {
            return @("docker-compose")
        }
    }

    throw "docker compose is required"
}

$script:ComposeCommand = $null

function Invoke-Compose {
    param([string[]]$Args)

    if (-not $script:ComposeCommand) {
        $script:ComposeCommand = Get-ComposeCommand
    }

    $exe = $script:ComposeCommand[0]
    $prefix = @()
    if ($script:ComposeCommand.Length -gt 1) {
        $prefix = $script:ComposeCommand[1..($script:ComposeCommand.Length - 1)]
    }

    & $exe @prefix @Args
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

function Initialize-Layout {
    New-Item -ItemType Directory -Force -Path $env:EXPERIENCE_DHT_DATA_DIR | Out-Null
    Write-Host "[config] set EXPERIENCE_DHT_INIT_PASSWORD before deployment"
}

function Test-EnvConfig {
    if (-not $env:EXPERIENCE_DHT_INIT_PASSWORD -or $env:EXPERIENCE_DHT_INIT_PASSWORD -eq "CHANGE_ME_DHT_INIT_PASSWORD") {
        throw "set EXPERIENCE_DHT_INIT_PASSWORD to the one-time bind password before deployment"
    }
}

function Test-Binary {
    $binary = Join-Path $PackageDir "bin\experience-dht"
    if (-not (Test-Path -LiteralPath $binary)) {
        throw "missing prebuilt binary: $binary. Build the deployment package on the development machine first."
    }
}

$ComposeFile = Join-Path $PackageDir "docker-compose.yml"
$ComposeBaseArgs = @("-p", $env:EXPERIENCE_DHT_PROJECT, "-f", $ComposeFile)

switch ($Mode) {
    "init" {
        Initialize-Layout
    }
    "up" {
        Initialize-Layout
        Test-EnvConfig
        Invoke-Compose ($ComposeBaseArgs + @("up", "-d"))
        Invoke-Compose ($ComposeBaseArgs + @("ps"))
    }
    "pull" {
        Invoke-Compose ($ComposeBaseArgs + @("pull"))
    }
    "build" {
        Initialize-Layout
        Test-Binary
        $alpineMirror = if ($env:EXPERIENCE_DHT_ALPINE_MIRROR) { $env:EXPERIENCE_DHT_ALPINE_MIRROR } else { "http://mirrors.aliyun.com/alpine" }
        docker build --build-arg "ALPINE_MIRROR=$alpineMirror" -t $env:EXPERIENCE_DHT_IMAGE $PackageDir
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
    "down" {
        Invoke-Compose ($ComposeBaseArgs + @("down"))
    }
    "logs" {
        Invoke-Compose ($ComposeBaseArgs + @("logs", "-f", "--tail", "120"))
    }
    "ps" {
        Invoke-Compose ($ComposeBaseArgs + @("ps"))
    }
    "reset" {
        Invoke-Compose ($ComposeBaseArgs + @("down"))
        if (Test-Path -LiteralPath $env:EXPERIENCE_DHT_DATA_DIR) {
            Remove-Item -LiteralPath $env:EXPERIENCE_DHT_DATA_DIR -Recurse -Force
        }
        Initialize-Layout
        Write-Host "[reset] removed DHT state. Run .\deploy.ps1 up, then bind again from the client."
    }
}
