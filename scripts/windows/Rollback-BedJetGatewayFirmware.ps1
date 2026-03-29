[CmdletBinding()]
param(
    [Parameter()]
    [string]$GatewayBaseUrl = '',

    [Parameter()]
    [string]$GatewayId = '',

    [Parameter()]
    [string]$GatewaySharedSecret = '',

    [Parameter()]
    [switch]$UseRemoteBaseUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SetupStatePath = Join-Path $RepoRoot 'data\setup-state.json'

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Get-SetupState {
    if (-not (Test-Path $SetupStatePath)) {
        return [ordered]@{}
    }

    $raw = Get-Content $SetupStatePath -Raw
    if (-not $raw.Trim()) {
        return [ordered]@{}
    }

    $json = $raw | ConvertFrom-Json
    $result = [ordered]@{}
    foreach ($property in $json.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }
    return $result
}

function Get-HmacSignature {
    param(
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][string]$Message
    )

    $hmac = [System.Security.Cryptography.HMACSHA256]::new([System.Text.Encoding]::UTF8.GetBytes($Secret))
    try {
        $hash = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Message))
    }
    finally {
        $hmac.Dispose()
    }

    return ([System.BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
}

function New-SignedHeaders {
    param(
        [Parameter(Mandatory)][string]$GatewayId,
        [Parameter(Mandatory)][string]$SharedSecret,
        [Parameter(Mandatory)][string]$Path
    )

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
    $nonceBytes = New-Object byte[] 12
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($nonceBytes)
    }
    finally {
        $rng.Dispose()
    }

    $nonce = ([System.BitConverter]::ToString($nonceBytes)).Replace('-', '').ToLowerInvariant()
    $message = @('POST', $Path, '', $timestamp, $nonce) -join "`n"
    $signature = Get-HmacSignature -Secret $SharedSecret -Message $message

    return @{
        'X-Gateway-Id' = $GatewayId
        'X-Timestamp' = $timestamp
        'X-Nonce' = $nonce
        'X-Signature' = $signature
    }
}

function Get-GatewayVersion {
    param(
        [Parameter(Mandatory)][string]$BaseUrl
    )

    return Invoke-RestMethod -Method GET -Uri ($BaseUrl + '/api/v1/version') -TimeoutSec 8
}

function Wait-GatewayOnline {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter()][int]$Attempts = 45,
        [Parameter()][int]$DelaySeconds = 2
    )

    for ($i = 1; $i -le $Attempts; $i += 1) {
        try {
            $null = Invoke-RestMethod -Method GET -Uri ($BaseUrl + '/healthz') -TimeoutSec 5
            return
        }
        catch {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw "Gateway did not come back online within $($Attempts * $DelaySeconds) seconds."
}

$state = Get-SetupState

$resolvedGatewayBaseUrl = if ($GatewayBaseUrl) {
    $GatewayBaseUrl
} elseif ($UseRemoteBaseUrl -and $state.Contains('gatewayRemoteBaseUrl') -and $state['gatewayRemoteBaseUrl']) {
    [string]$state['gatewayRemoteBaseUrl']
} elseif ($state.Contains('gatewayBaseUrl') -and $state['gatewayBaseUrl']) {
    [string]$state['gatewayBaseUrl']
} else {
    ''
}

$resolvedGatewayId = if ($GatewayId) {
    $GatewayId
} elseif ($state.Contains('gatewayId') -and $state['gatewayId']) {
    [string]$state['gatewayId']
} else {
    ''
}

$resolvedGatewaySharedSecret = if ($GatewaySharedSecret) {
    $GatewaySharedSecret
} elseif ($state.Contains('gatewaySharedSecret') -and $state['gatewaySharedSecret']) {
    [string]$state['gatewaySharedSecret']
} else {
    ''
}

if (-not $resolvedGatewayBaseUrl) {
    throw 'Gateway base URL not resolved. Pass -GatewayBaseUrl or run setup first.'
}
if (-not $resolvedGatewayId) {
    throw 'GatewayId not resolved. Pass -GatewayId or run setup first.'
}
if (-not $resolvedGatewaySharedSecret) {
    throw 'GatewaySharedSecret not resolved. Pass -GatewaySharedSecret or run setup first.'
}

$resolvedGatewayBaseUrl = $resolvedGatewayBaseUrl.TrimEnd('/')

Write-Step 'Step 1: check rollback availability'
$before = Get-GatewayVersion -BaseUrl $resolvedGatewayBaseUrl
if (-not $before.firmware.canRollback) {
    throw 'Gateway reports that no rollback image is currently available.'
}
$beforeBuild = [string]$before.firmware.buildId
Write-Ok "Rollback is available from build '$beforeBuild'"

Write-Step 'Step 2: request signed rollback'
$rollbackPath = '/api/v1/firmware/rollback'
$headers = New-SignedHeaders -GatewayId $resolvedGatewayId -SharedSecret $resolvedGatewaySharedSecret -Path $rollbackPath
$response = Invoke-RestMethod -Method POST -Uri ($resolvedGatewayBaseUrl + $rollbackPath) -Headers $headers -TimeoutSec 8
if (-not $response.ok) {
    throw 'Gateway rollback did not report success.'
}
Write-Ok 'Gateway accepted rollback and is restarting'

Write-Step 'Step 3: post-rollback attestation'
Wait-GatewayOnline -BaseUrl $resolvedGatewayBaseUrl
Start-Sleep -Seconds 2

$after = $null
for ($attempt = 1; $attempt -le 20; $attempt += 1) {
    $after = Get-GatewayVersion -BaseUrl $resolvedGatewayBaseUrl
    if ($after -and $after.firmware -and ([string]$after.firmware.ota.lastStatus -in @('rolled-back', 'rolled-back-pending-reboot'))) {
        break
    }
    Start-Sleep -Seconds 2
}

if (-not $after -or -not $after.firmware -or ([string]$after.firmware.ota.lastStatus -notin @('rolled-back', 'rolled-back-pending-reboot'))) {
    throw 'Gateway rollback attestation did not converge.'
}

$afterBuild = [string]$after.firmware.buildId
$afterStatus = [string]$after.firmware.ota.lastStatus
Write-Ok "Gateway rollback attested with OTA status '$afterStatus'"
Write-Ok "Gateway build after rollback: '$afterBuild'"
