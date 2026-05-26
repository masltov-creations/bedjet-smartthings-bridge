[CmdletBinding()]
param(
    [switch]$OutputJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetNames = @('bedjet-unit.v1', 'bedjet-nightly-bio.v1')

function Get-BedJetDevices {
    $devices = smartthings devices --json | ConvertFrom-Json
    return @($devices | Where-Object { $targetNames -contains $_.name })
}

function Get-RuntimeSide {
    param(
        [Parameter(Mandatory)]
        $DeviceDetails
    )

    $networkId = ''
    if ($DeviceDetails.lan -and $DeviceDetails.lan.networkId) {
        $networkId = [string]$DeviceDetails.lan.networkId
    }

    if ($networkId -match 'right') {
        return 'right'
    }

    if ($networkId -match 'left') {
        return 'left'
    }

    $model = [string]$DeviceDetails.deviceModel
    if ($model -match 'Right') {
        return 'right'
    }

    if ($model -match 'Left') {
        return 'left'
    }

    return ''
}

function Get-PreferenceValue {
    param(
        [Parameter(Mandatory)]
        $Prefs,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not $Prefs.values.PSObject.Properties[$Name]) {
        return $null
    }

    return $Prefs.values.$Name.value
}

$devices = Get-BedJetDevices
if ($devices.Count -eq 0) {
    throw 'No BedJet SmartThings devices found. Ensure discovery/installation has completed.'
}

$rows = @()
$errors = @()
$warnings = @()

foreach ($device in $devices) {
    $prefs = smartthings devices:preferences $device.deviceId --json | ConvertFrom-Json
    $details = smartthings devices $device.deviceId --json | ConvertFrom-Json

    $bridgeHost = [string](Get-PreferenceValue -Prefs $prefs -Name 'bridgeHost')
    $bridgePort = Get-PreferenceValue -Prefs $prefs -Name 'bridgePort'
    $bridgeFallbackIp = [string](Get-PreferenceValue -Prefs $prefs -Name 'bridgeFallbackIp')
    $runtimeSide = Get-RuntimeSide -DeviceDetails $details
    $networkId = if ($details.lan -and $details.lan.networkId) { [string]$details.lan.networkId } else { '' }

    $rows += [pscustomobject]@{
        deviceId = $device.deviceId
        label = $device.label
        name = $device.name
        runtimeSide = $runtimeSide
        networkId = $networkId
        bridgeHost = $bridgeHost
        bridgeFallbackIp = $bridgeFallbackIp
        bridgePort = $bridgePort
    }

    if ([string]::IsNullOrWhiteSpace($bridgeHost) -or $bridgeHost -eq 'bridge-host-or-ip') {
        $errors += "[$($device.label)] bridgeHost is not configured (current: '$bridgeHost')."
    }

    if (-not ($bridgePort -is [int]) -or $bridgePort -lt 1 -or $bridgePort -gt 65535) {
        $errors += "[$($device.label)] bridgePort is invalid (current: '$bridgePort')."
    }

    if ([string]::IsNullOrWhiteSpace($runtimeSide)) {
        $errors += "[$($device.label)] unable to infer runtime side from device metadata (networkId='$networkId', model='$([string]$details.deviceModel)')."
    }

    if ([string]::IsNullOrWhiteSpace($bridgeFallbackIp)) {
        $warnings += "[$($device.label)] bridgeFallbackIp is empty. Strongly recommended to set LAN IPv4 fallback."
    }
}

$leftCount = @($rows | Where-Object { $_.runtimeSide -eq 'left' }).Count
$rightCount = @($rows | Where-Object { $_.runtimeSide -eq 'right' }).Count
if ($leftCount -eq 0 -or $rightCount -eq 0) {
    $errors += "Runtime side imbalance: left=$leftCount right=$rightCount. Both sides must be represented."
}

$summary = [pscustomobject]@{
    ok = ($errors.Count -eq 0)
    checkedAt = (Get-Date).ToString('o')
    devices = $rows
    errors = $errors
    warnings = $warnings
}

if ($OutputJson) {
    $summary | ConvertTo-Json -Depth 8
} else {
    Write-Host 'SmartThings BedJet Routing Validation'
    Write-Host ('  Devices checked: {0}' -f $rows.Count)
    Write-Host ('  Left mapped:     {0}' -f $leftCount)
    Write-Host ('  Right mapped:    {0}' -f $rightCount)

    if ($warnings.Count -gt 0) {
        Write-Host ''
        Write-Host 'Warnings:' -ForegroundColor Yellow
        foreach ($warning in $warnings) {
            Write-Host ('  - {0}' -f $warning) -ForegroundColor Yellow
        }
    }

    if ($errors.Count -gt 0) {
        Write-Host ''
        Write-Host 'Errors:' -ForegroundColor Red
        foreach ($error in $errors) {
            Write-Host ('  - {0}' -f $error) -ForegroundColor Red
        }
    }
}

if (-not $summary.ok) {
    exit 1
}

Write-Host ''
Write-Host 'SmartThings routing configuration looks valid.' -ForegroundColor Green
