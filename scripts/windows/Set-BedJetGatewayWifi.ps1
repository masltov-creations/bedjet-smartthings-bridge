[CmdletBinding()]
param(
    [Parameter()]
    [string]$GatewayBaseUrl = '',

    [Parameter()]
    [string]$GatewayId = '',

    [Parameter()]
    [string]$GatewaySharedSecret = '',

    [Parameter(Mandatory)]
    [string]$WifiSsid,

    [Parameter()]
    [string]$WifiPassword = '',

    [Parameter()]
    [string]$GatewayHostname = 'bedjet-gateway'
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
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Body
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
    $message = @('POST', $Path, $Body, $timestamp, $nonce) -join "`n"
    $signature = Get-HmacSignature -Secret $SharedSecret -Message $message

    return @{
        'X-Gateway-Id' = $GatewayId
        'X-Timestamp' = $timestamp
        'X-Nonce' = $nonce
        'X-Signature' = $signature
    }
}

$state = Get-SetupState
$resolvedGatewayBaseUrl = if ($GatewayBaseUrl) { $GatewayBaseUrl } elseif ($state['gatewayBaseUrl']) { [string]$state['gatewayBaseUrl'] } else { '' }
$resolvedGatewayId = if ($GatewayId) { $GatewayId } elseif ($state['gatewayId']) { [string]$state['gatewayId'] } else { '' }
$resolvedGatewaySharedSecret = if ($GatewaySharedSecret) { $GatewaySharedSecret } elseif ($state['gatewaySharedSecret']) { [string]$state['gatewaySharedSecret'] } else { '' }

if (-not $resolvedGatewayBaseUrl) {
    throw 'GatewayBaseUrl not resolved. Pass -GatewayBaseUrl or run setup first.'
}
if (-not $resolvedGatewayId) {
    throw 'GatewayId not resolved. Pass -GatewayId or run setup first.'
}
if (-not $resolvedGatewaySharedSecret) {
    throw 'GatewaySharedSecret not resolved. Pass -GatewaySharedSecret or run setup first.'
}

$resolvedGatewayBaseUrl = $resolvedGatewayBaseUrl.TrimEnd('/')
$path = '/api/v1/provision/wifi'
$body = @{
    ssid = $WifiSsid
    password = $WifiPassword
    hostname = $GatewayHostname
} | ConvertTo-Json -Compress
$headers = New-SignedHeaders -GatewayId $resolvedGatewayId -SharedSecret $resolvedGatewaySharedSecret -Path $path -Body $body

Write-Step 'Step 1: signed Wi-Fi update'
$response = Invoke-RestMethod -Method POST -Uri ($resolvedGatewayBaseUrl + $path) -Headers $headers -Body $body -ContentType 'application/json' -TimeoutSec 8
if (-not $response.ok) {
    throw 'Gateway Wi-Fi update did not report success.'
}
Write-Ok "Gateway accepted Wi-Fi update for SSID $WifiSsid"

Write-Step 'Step 2: note restart'
Write-Host 'Gateway will reboot onto the updated network settings. If hostname or SSID changed, its old URL may stop responding.' -ForegroundColor Yellow
