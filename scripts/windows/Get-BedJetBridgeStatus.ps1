[CmdletBinding()]
param(
    [Parameter()]
    [string]$SshTarget = '',

    [Parameter()]
    [int]$BridgePort = 8787
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$SetupStatePath = Join-Path $RepoRoot 'data\setup-state.json'

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

function Resolve-SshTarget {
    param(
        [Parameter(Mandatory)]
        [string]$ProvidedTarget,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$State
    )

    $candidate = $ProvidedTarget.Trim()
    if (-not $candidate -and $State.Contains('sshTarget') -and $State['sshTarget']) {
        $candidate = [string]$State['sshTarget']
    }
    $candidate = $candidate.Trim()
    if (-not $candidate) {
        throw 'SSH target is required. Pass -SshTarget user@host or run Setup-BedJetBridge.ps1 first so data/setup-state.json includes sshTarget.'
    }
    return $candidate
}

function Get-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    switch ($Name.ToLowerInvariant()) {
        'cmd' {
            if ($env:ComSpec -and (Test-Path $env:ComSpec)) {
                return $env:ComSpec
            }
            return (Join-Path $env:WINDIR 'System32\cmd.exe')
        }
        'ssh' {
            return (Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe')
        }
    }

    throw "Required command not found: $Name"
}

function Invoke-CommandShell {
    param(
        [Parameter(Mandatory)]
        [string]$CommandLine
    )

    $cmd = Get-NativeCommand -Name 'cmd'
    Write-Host ("$cmd /d /c $CommandLine 2>&1") -ForegroundColor DarkGray
    $output = & $cmd /d /c "$CommandLine 2>&1"
    $exitCode = 0
    if (Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue) {
        $exitCode = $global:LASTEXITCODE
    }

    $text = ($output | ForEach-Object { "$_" }) -join [Environment]::NewLine
    if ($text) {
        Write-Host $text
    }

    if ($exitCode -ne 0) {
        throw "Command failed with exit code $exitCode"
    }

    return $text
}

$state = Get-SetupState
$resolvedSshTarget = Resolve-SshTarget -ProvidedTarget $SshTarget -State $state
$ssh = Get-NativeCommand -Name 'ssh'
$remoteScript = @'
set -e
curl -fsS http://127.0.0.1:'@ + $BridgePort + @'/v1/system
'@

$escapedRemoteScript = $remoteScript.Replace('"', '\"').Replace("`r", '').Replace("`n", '; ')
$commandLine = '"' + $ssh + '" -o BatchMode=yes -o ConnectTimeout=8 ' + $resolvedSshTarget + ' "bash -lc ""' + $escapedRemoteScript + '"""'
$output = Invoke-CommandShell -CommandLine $commandLine

$system = $output | ConvertFrom-Json

$status = [ordered]@{
    bridge_ok = $true
    bridge_port = $system.bridge.port
    bridge_host = $system.bridge.host
    bridge_gateway_url = $system.bridge.firmwareApiBaseUrl
    bridge_gateway_id = $system.bridge.firmwareGatewayId
    bridge_secret_configured = [bool]$system.bridge.firmwareSharedSecretConfigured
    gateway_claimed = [bool]$system.gatewayClaim.claimed
    gateway_state_claimed = [bool]$system.gatewayState.claim.claimed
}

Write-Host ''
$status | ConvertTo-Json -Depth 5
