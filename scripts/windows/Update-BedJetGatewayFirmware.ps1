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
    [switch]$UseRemoteBaseUrl,

    [Parameter()]
    [switch]$RollbackOnFailedAttestation
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
        [Parameter()][ValidateSet('GET', 'POST')][string]$Method = 'POST',
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][string]$BodyMarker = '',
        [Parameter()][string]$FirmwareSha256 = ''
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
    $message = @($Method.ToUpperInvariant(), $Path, $BodyMarker, $timestamp, $nonce) -join "`n"
    $signature = Get-HmacSignature -Secret $SharedSecret -Message $message

    $headers = @{
        'X-Gateway-Id' = $GatewayId
        'X-Timestamp' = $timestamp
        'X-Nonce' = $nonce
        'X-Signature' = $signature
    }
    if ($FirmwareSha256) {
        $headers['X-Firmware-SHA256'] = $FirmwareSha256
    }
    return $headers
}

function Get-GatewayVersion {
    param(
        [Parameter(Mandatory)][string]$BaseUrl
    )

    try {
        return Invoke-RestMethod -Method GET -Uri ($BaseUrl + '/api/v1/version') -TimeoutSec 8
    }
    catch {
        return $null
    }
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

function Invoke-GatewayRollback {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$GatewayId,
        [Parameter(Mandatory)][string]$SharedSecret,
        [Parameter()][string]$ExpectedPriorBuild = ''
    )

    Write-Step 'Step 5: signed rollback'
    $rollbackPath = '/api/v1/firmware/rollback'
    $headers = New-SignedHeaders -GatewayId $GatewayId -SharedSecret $SharedSecret -Path $rollbackPath
    $rollback = Invoke-RestMethod -Method POST -Uri ($BaseUrl + $rollbackPath) -Headers $headers -TimeoutSec 8
    if (-not $rollback.ok) {
        throw 'Gateway rollback request did not report success.'
    }
    Write-Ok 'Gateway accepted rollback and is restarting'

    Wait-GatewayOnline -BaseUrl $BaseUrl
    Start-Sleep -Seconds 2

    $afterRollback = $null
    for ($attempt = 1; $attempt -le 20; $attempt += 1) {
        $afterRollback = Get-GatewayVersion -BaseUrl $BaseUrl
        if ($afterRollback -and $afterRollback.firmware -and ([string]$afterRollback.firmware.ota.lastStatus -in @('rolled-back', 'rolled-back-pending-reboot'))) {
            break
        }
        Start-Sleep -Seconds 2
    }

    if (-not $afterRollback -or -not $afterRollback.firmware -or ([string]$afterRollback.firmware.ota.lastStatus -notin @('rolled-back', 'rolled-back-pending-reboot'))) {
        throw 'Gateway rollback did not attest cleanly.'
    }

    $rolledBackBuild = [string]$afterRollback.firmware.buildId
    $rollbackStatus = [string]$afterRollback.firmware.ota.lastStatus
    Write-Ok "Gateway rollback attested with OTA status '$rollbackStatus'"
    if ($ExpectedPriorBuild -and $rolledBackBuild -eq $ExpectedPriorBuild) {
        Write-Ok "Gateway build returned to prior build '$rolledBackBuild'"
    } elseif ($rolledBackBuild) {
        Write-Ok "Gateway build after rollback: '$rolledBackBuild'"
    }
}

function Get-CurlPath {
    $candidate = Join-Path $env:WINDIR 'System32\curl.exe'
    if (Test-Path $candidate) {
        return $candidate
    }
    $fromPath = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($fromPath -and $fromPath.Source) {
        return $fromPath.Source
    }
    throw 'curl.exe not found on this machine.'
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

$beforeVersion = Get-GatewayVersion -BaseUrl $resolvedGatewayBaseUrl
if ($beforeVersion -and $beforeVersion.firmware -and $beforeVersion.firmware.buildId) {
    $beforeBuild = [string]$beforeVersion.firmware.buildId
    $beforeSketchMd5 = [string]$beforeVersion.firmware.sketchMd5
    $beforeBootCount = [int]$beforeVersion.firmware.bootCount
    $beforeCanRollback = [bool]$beforeVersion.firmware.canRollback
    Write-Ok "Current firmware build: $beforeBuild"
    if ($beforeSketchMd5) {
        Write-Ok "Current firmware sketch MD5: $beforeSketchMd5"
    }
    Write-Ok ("Rollback available before update: {0}" -f ($beforeCanRollback ? 'Yes' : 'No'))
} else {
    Write-Host '[wait] Version endpoint unavailable on current firmware; post-update attestation will rely on health + OTA status fields when available.' -ForegroundColor Yellow
}

Write-Step 'Step 2: hash firmware binary'
$firmwareSha256 = (Get-FileHash -Algorithm SHA256 -Path $resolvedFirmwarePath).Hash.ToLowerInvariant()
$bodyMarker = "sha256:$firmwareSha256"
Write-Ok "Firmware SHA256: $firmwareSha256"

Write-Step 'Step 3: upload signed firmware update'
$headers = New-SignedHeaders -GatewayId $resolvedGatewayId -SharedSecret $resolvedGatewaySharedSecret -Path $updatePath -BodyMarker $bodyMarker -FirmwareSha256 $firmwareSha256
$response = $null
$uploadHadReset = $false
try {
    $curl = Get-CurlPath
    $curlArgs = @(
        '-sS',
        '-X', 'POST',
        '-H', "X-Gateway-Id: $($headers['X-Gateway-Id'])",
        '-H', "X-Timestamp: $($headers['X-Timestamp'])",
        '-H', "X-Nonce: $($headers['X-Nonce'])",
        '-H', "X-Signature: $($headers['X-Signature'])",
        '-H', "X-Firmware-SHA256: $($headers['X-Firmware-SHA256'])",
        '-F', "firmware=@$resolvedFirmwarePath;type=application/octet-stream",
        $updateUri
    )
    $global:LASTEXITCODE = 0
    $raw = & $curl @curlArgs
    $curlExitCode = $global:LASTEXITCODE
    if ($curlExitCode -ne 0) {
        throw "curl upload failed with exit code $curlExitCode"
    }
    if ($raw) {
        Write-Host $raw
    }
    $response = $raw | ConvertFrom-Json
}
catch {
    if (($_.Exception.Message -match 'underlying connection was closed') -or ($_.Exception.Message -match 'exit code 56')) {
        $uploadHadReset = $true
        Write-Host '[wait] Upload connection reset while gateway restarted; continuing with post-reboot attestation.' -ForegroundColor Yellow
    } else {
        throw
    }
}

if ($response -and -not $response.ok) {
    throw 'Gateway firmware update did not report success.'
}

if ($response -and $response.ok) {
    Write-Ok "Gateway accepted firmware ($($response.bytes) bytes) and is restarting."
} elseif ($uploadHadReset) {
    Write-Ok 'Gateway restart detected during OTA response.'
}

Write-Step 'Step 4: post-update attestation'
Wait-GatewayOnline -BaseUrl $resolvedGatewayBaseUrl
Start-Sleep -Seconds 2

$afterVersion = $null
$attested = $false
for ($attempt = 1; $attempt -le 30; $attempt += 1) {
    $afterVersion = Get-GatewayVersion -BaseUrl $resolvedGatewayBaseUrl
    if (-not $afterVersion -or -not $afterVersion.firmware) {
        Start-Sleep -Seconds 2
        continue
    }

    $afterStatus = [string]$afterVersion.firmware.ota.lastStatus
    $afterSha = [string]$afterVersion.firmware.ota.lastSha256
    $afterBootCount = [int]$afterVersion.firmware.bootCount
    $bootAdvanced = $true
    if ($beforeVersion -and $beforeVersion.firmware) {
        $bootAdvanced = $afterBootCount -gt [int]$beforeVersion.firmware.bootCount
    }

    if (($afterStatus -in @('applied', 'applied-pending-reboot')) -and ($afterSha -eq $firmwareSha256) -and $bootAdvanced) {
        $attested = $true
        break
    }

    Start-Sleep -Seconds 2
}

if (-not $attested) {
    if ($RollbackOnFailedAttestation) {
        Invoke-GatewayRollback -BaseUrl $resolvedGatewayBaseUrl -GatewayId $resolvedGatewayId -SharedSecret $resolvedGatewaySharedSecret -ExpectedPriorBuild $beforeBuild
        throw 'Gateway OTA attestation did not converge; automatic rollback completed.'
    }
    throw 'Gateway OTA attestation did not converge (status/sha/bootCount mismatch).'
}

$afterBuild = [string]$afterVersion.firmware.buildId
$afterSketchMd5 = [string]$afterVersion.firmware.sketchMd5
$afterStatus = [string]$afterVersion.firmware.ota.lastStatus
$afterSha = [string]$afterVersion.firmware.ota.lastSha256
$afterBootCount = [int]$afterVersion.firmware.bootCount
$afterCanRollback = [bool]$afterVersion.firmware.canRollback

if ($beforeVersion -and $beforeVersion.firmware) {
    $beforeBuild = [string]$beforeVersion.firmware.buildId
    if ($beforeBuild -ne $afterBuild) {
        Write-Ok "Firmware build changed: '$beforeBuild' -> '$afterBuild'"
    } else {
        Write-Ok "Firmware build ID unchanged ('$afterBuild'); attested via OTA SHA + boot count."
    }
    if ($beforeSketchMd5 -and $afterSketchMd5) {
        if ($beforeSketchMd5 -ne $afterSketchMd5) {
            Write-Ok "Firmware sketch MD5 changed: $beforeSketchMd5 -> $afterSketchMd5"
        } else {
            Write-Ok "Firmware sketch MD5 unchanged: $afterSketchMd5"
        }
    }
    Write-Ok "Gateway boot count: $beforeBootCount -> $afterBootCount"
} else {
    Write-Ok "Firmware build after update: '$afterBuild'"
}
if (-not $afterSketchMd5) {
    throw 'Gateway firmware sketch MD5 is missing; attestation incomplete.'
}
Write-Ok 'Gateway OTA attestation passed (status + SHA256).'
Write-Ok ("Rollback available after update: {0}" -f ($afterCanRollback ? 'Yes' : 'No'))
