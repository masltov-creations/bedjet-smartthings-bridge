[CmdletBinding()]
param(
    [Parameter()]
    [string]$GatewayBaseUrl = '',

    [Parameter()]
    [string]$GatewayId = '',

    [Parameter()]
    [string]$GatewaySharedSecret = '',

    [Parameter()]
    [string]$FirmwarePath = '',

    [Parameter()]
    [switch]$UseRemoteBaseUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SetupStatePath = Join-Path $RepoRoot 'data\setup-state.json'
$DefaultFirmwarePath = Join-Path $RepoRoot 'firmware\.pio\build\esp32-s3-devkitc-1\firmware.bin'

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
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BodyMarker,
        [Parameter(Mandatory)][string]$FirmwareSha256
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
    $message = @('POST', $Path, $BodyMarker, $timestamp, $nonce) -join "`n"
    $signature = Get-HmacSignature -Secret $SharedSecret -Message $message

    return @{
        'X-Gateway-Id' = $GatewayId
        'X-Timestamp' = $timestamp
        'X-Nonce' = $nonce
        'X-Signature' = $signature
        'X-Firmware-SHA256' = $FirmwareSha256
    }
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

$resolvedFirmwarePath = if ($FirmwarePath) { $FirmwarePath } else { $DefaultFirmwarePath }

if (-not $resolvedGatewayBaseUrl) {
    throw 'Gateway base URL not resolved. Pass -GatewayBaseUrl or run setup first.'
}
if (-not $resolvedGatewayId) {
    throw 'GatewayId not resolved. Pass -GatewayId or run setup first.'
}
if (-not $resolvedGatewaySharedSecret) {
    throw 'GatewaySharedSecret not resolved. Pass -GatewaySharedSecret or run setup first.'
}
if (-not (Test-Path $resolvedFirmwarePath)) {
    throw "Firmware binary not found at: $resolvedFirmwarePath"
}

$resolvedGatewayBaseUrl = $resolvedGatewayBaseUrl.TrimEnd('/')
$updatePath = '/api/v1/firmware/update'
$updateUri = $resolvedGatewayBaseUrl + $updatePath

Write-Step 'Step 1: check gateway claim'
$claim = Invoke-RestMethod -Method GET -Uri ($resolvedGatewayBaseUrl + '/api/v1/claim/status')
if (-not $claim.claimed) {
    throw 'Gateway is not claimed. Run setup claim flow first.'
}
if ($claim.gatewayId -ne $resolvedGatewayId) {
    throw "Gateway claimed by '$($claim.gatewayId)', expected '$resolvedGatewayId'."
}
Write-Ok "Gateway claim verified for $resolvedGatewayId"

Write-Step 'Step 2: hash firmware binary'
$firmwareSha256 = (Get-FileHash -Algorithm SHA256 -Path $resolvedFirmwarePath).Hash.ToLowerInvariant()
$bodyMarker = "sha256:$firmwareSha256"
Write-Ok "Firmware SHA256: $firmwareSha256"

Write-Step 'Step 3: upload signed firmware update'
$headers = New-SignedHeaders -GatewayId $resolvedGatewayId -SharedSecret $resolvedGatewaySharedSecret -Path $updatePath -BodyMarker $bodyMarker -FirmwareSha256 $firmwareSha256
$response = Invoke-RestMethod -Method POST -Uri $updateUri -Headers $headers -InFile $resolvedFirmwarePath -ContentType 'application/octet-stream' -TimeoutSec 240

if (-not $response.ok) {
    throw 'Gateway firmware update did not report success.'
}

Write-Ok "Gateway accepted firmware ($($response.bytes) bytes) and is restarting."
