[CmdletBinding()]
param(
  [ValidateSet('mute','unmute')]
  [string]$Mode = 'mute',
  [ValidateSet('left','right','both')]
  [string]$Side = 'both',
  [string]$GatewayBaseUrl,
  [string]$SetupStatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $SetupStatePath) {
  $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
  $SetupStatePath = Join-Path $scriptRoot '..\..\data\setup-state.json'
}

function Resolve-GatewayBaseUrl {
  param(
    [string]$Provided,
    [string]$StatePath
  )

  if ($Provided) {
    return $Provided.TrimEnd('/')
  }

  if (-not (Test-Path $StatePath)) {
    throw "GatewayBaseUrl not provided and setup-state not found at: $StatePath"
  }

  $state = Get-Content -Raw -Path $StatePath | ConvertFrom-Json
  $url = $state.gatewayBaseUrl
  if (-not $url) {
    throw "gatewayBaseUrl not found in setup-state: $StatePath"
  }

  return $url.TrimEnd('/')
}

$gateway = Resolve-GatewayBaseUrl -Provided $GatewayBaseUrl -StatePath $SetupStatePath
$beepMuted = $Mode -eq 'mute'
$body = @{ beepMuted = $beepMuted } | ConvertTo-Json -Compress

$sides = if ($Side -eq 'both') { @('left','right') } else { @($Side) }

Write-Host "Gateway: $gateway"
Write-Host "Mode: $Mode"

foreach ($s in $sides) {
  $uri = "$gateway/api/v1/local/command/$s"
  $response = Invoke-RestMethod -Method Post -Uri $uri -ContentType 'application/json' -Body $body

  if (-not $response.ok) {
    throw "Command failed for side '$s'."
  }

  $status = $response.status
  $mutedText = if ($beepMuted) { 'muted' } else { 'unmuted' }
  Write-Host ("[$s] beep {0}; power={1}, mode={2}, fanStep={3}, targetTemperatureC={4}" -f $mutedText, $status.power, $status.mode, $status.fanStep, $status.targetTemperatureC)
}

Write-Host 'Done.'
