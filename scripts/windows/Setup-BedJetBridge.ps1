[CmdletBinding()]
param(
    [Parameter()]
    [string]$SshTarget = '',

    [Parameter()]
    [string]$InstallDir = '~/apps/bedjet-smartthings-bridge',

    [Parameter()]
    [int]$BridgePort = 8787,

    [Parameter()]
    [string]$GatewayBaseUrl = '',

    [Parameter()]
    [string]$GatewayId = '',

    [Parameter()]
    [string]$GatewaySharedSecret = '',

    [Parameter()]
    [switch]$AutoApprove,

    [Parameter()]
    [switch]$SkipDeploy,

    [Parameter()]
    [switch]$SkipRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$BridgeRoot = Join-Path $RepoRoot 'bridge'
$DeployRoot = Join-Path $RepoRoot 'deploy\bridge'
$StageRoot = Join-Path $env:TEMP 'bedjet-bridge-deploy'
$BundleRoot = Join-Path $StageRoot 'bundle'
$ArchivePath = Join-Path $StageRoot 'bedjet-bridge-bundle.tgz'
$SetupStatePath = Join-Path $RepoRoot 'data\setup-state.json'
$script:ResolvedGatewayBaseUrl = ''
$script:ResolvedGatewayRemoteBaseUrl = ''
$script:ResolvedGatewayId = ''
$script:ResolvedGatewaySharedSecret = ''
$script:ResolvedBridgeLanUrl = ''
$script:ResolvedSmartThingsBridgeHost = ''
$script:ResolvedSshTarget = ''

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host "[ok] $Message" -ForegroundColor Green
}

function Confirm-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    if ($AutoApprove) {
        return $true
    }

    while ($true) {
        $answer = Read-Host "$Prompt [y/n]"
        switch ($answer.ToLowerInvariant()) {
            'y' { return $true }
            'n' { return $false }
        }
    }
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

function Save-SetupState {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$State
    )

    $stateDir = Split-Path -Parent $SetupStatePath
    if (-not (Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir | Out-Null
    }

    $State | ConvertTo-Json -Depth 8 | Set-Content -Path $SetupStatePath
}

function Get-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $candidates = @()

    try {
        $command = Get-Command $Name -ErrorAction Stop
        if ($command.Source) {
            return $command.Source
        }
    }
    catch {
    }

    switch ($Name.ToLowerInvariant()) {
        'cmd' {
            if ($env:ComSpec) {
                $candidates += @($env:ComSpec)
            }
            $candidates += @((Join-Path $env:WINDIR 'System32\cmd.exe'))
        }
        'ssh' {
            $candidates += @((Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'))
        }
        'scp' {
            $candidates += @((Join-Path $env:WINDIR 'System32\OpenSSH\scp.exe'))
        }
        'tar' {
            $candidates += @(
                (Join-Path $env:WINDIR 'System32\tar.exe'),
                (Join-Path $env:WINDIR 'System32\bsdtar.exe')
            )
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "Required command not found: $Name"
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter()]
        [string[]]$ArgumentList = @(),

        [Parameter()]
        [switch]$AllowFailure
    )

    Write-Host ("$FilePath " + ($ArgumentList -join ' ')) -ForegroundColor DarkGray

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $escapedArguments = foreach ($argument in $ArgumentList) {
        if ($argument -match '[\s"]') {
            '"' + ($argument -replace '(\\*)"', '$1$1\"') + '"'
        } else {
            $argument
        }
    }
    $startInfo.Arguments = ($escapedArguments -join ' ')

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode

    $textParts = @()
    if ($stdout) {
        $textParts += $stdout.TrimEnd()
    }
    if ($stderr) {
        $textParts += $stderr.TrimEnd()
    }
    $text = $textParts -join [Environment]::NewLine
    if ($text) {
        Write-Host $text
    }

    if (($exitCode -ne 0) -and -not $AllowFailure) {
        throw "Command failed with exit code $exitCode"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output = $text
        Ok = ($exitCode -eq 0)
    }
}

function Invoke-CommandShell {
    param(
        [Parameter(Mandatory)]
        [string]$CommandLine,

        [Parameter()]
        [switch]$AllowFailure
    )

    $cmd = Get-NativeCommand -Name 'cmd'
    return Invoke-Native -FilePath $cmd -ArgumentList @('/d', '/c', "$CommandLine 2>&1") -AllowFailure:$AllowFailure
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter()]
        [switch]$AllowFailure
    )

    $ssh = Get-NativeCommand -Name 'ssh'
    return Invoke-Native -FilePath $ssh -ArgumentList $ArgumentList -AllowFailure:$AllowFailure
}

function Wait-RemoteHttpGet {
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter()]
        [int]$Attempts = 12,

        [Parameter()]
        [int]$DelaySeconds = 2
    )

    $lastResult = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $lastResult = Invoke-Ssh -ArgumentList @(
            '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=8',
            $Target,
            "curl -fsS $Url"
        ) -AllowFailure

        if ($lastResult.Ok) {
            return $lastResult
        }

        if ($attempt -lt $Attempts) {
            Write-Host ("[wait] remote GET failed for {0} (attempt {1}/{2}); retrying in {3}s" -f $Url, $attempt, $Attempts, $DelaySeconds) -ForegroundColor DarkYellow
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $message = "Remote GET failed for $Url after $Attempts attempts."
    if ($lastResult -and $lastResult.Output) {
        $message += " Last output: $($lastResult.Output)"
    }
    throw $message
}

function Invoke-Scp {
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [Parameter()]
        [switch]$AllowFailure
    )

    $scp = Get-NativeCommand -Name 'scp'
    return Invoke-Native -FilePath $scp -ArgumentList $ArgumentList -AllowFailure:$AllowFailure
}

function Test-CommandVersion {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string[]]$VersionArgs = @('--version')
    )

    $path = Get-NativeCommand -Name $Name
    $result = Invoke-Native -FilePath $path -ArgumentList $VersionArgs -AllowFailure

    [pscustomobject]@{
        Name = $Name
        Path = $path
        Version = $result.Output.Trim()
        Ok = $true
    }
}

function Test-SshBatchMode {
    param(
        [Parameter(Mandatory)]
        [string]$Target
    )

    $result = Invoke-Ssh -ArgumentList @(
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=5',
        $Target,
        'printf __bedjet_setup_ok__'
    ) -AllowFailure

    if (-not $result.Ok -or $result.Output -notmatch '__bedjet_setup_ok__') {
        $detail = if ($result.Output) { $result.Output.Trim() } else { 'No SSH output captured.' }
        throw "SSH batch mode failed for $Target. Output: $detail"
    }
}

function Get-RemoteFacts {
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter()]
        [string]$GatewayIp = ''
    )

    $escapedGatewayIp = $GatewayIp.Replace("'", "'""'""'")
    $script = @'
set +e
GATEWAY_IP='__GATEWAY_IP__'
LAN_IP=""
if [[ -n "$GATEWAY_IP" ]]; then
  LAN_IP="$(ip -4 route get "$GATEWAY_IP" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") { print $(i+1); exit }}')"
fi
if [[ -z "$LAN_IP" ]]; then
  LAN_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' | head -n 1)"
fi
TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1)"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
command -v docker >/dev/null 2>&1 && echo has_docker=1 || echo has_docker=0
docker info >/dev/null 2>&1 && echo daemon_usable=1 || echo daemon_usable=0
docker compose version >/dev/null 2>&1 && echo compose_available=1 || echo compose_available=0
command -v tailscale >/dev/null 2>&1 && echo has_tailscale=1 || echo has_tailscale=0
tailscale status --json >/dev/null 2>&1 && echo tailscale_logged_in=1 || echo tailscale_logged_in=0
[[ -n "$LAN_IP" ]] && echo lan_ip="$LAN_IP" || echo lan_ip=
[[ -n "$TAILSCALE_IP" ]] && echo tailscale_ip="$TAILSCALE_IP" || echo tailscale_ip=
[[ -n "$HOST_FQDN" ]] && echo host_fqdn="$HOST_FQDN" || echo host_fqdn=
'@
    $script = $script.Replace('__GATEWAY_IP__', $escapedGatewayIp)

    $result = Invoke-Ssh -ArgumentList @(
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=8',
        $Target,
        'bash',
        '-lc',
        $script
    ) -AllowFailure

    if (-not $result.Ok) {
        $detail = if ($result.Output) { $result.Output.Trim() } else { 'No SSH output captured.' }
        throw "Remote precheck failed for $Target. Output: $detail"
    }

    $facts = @{}
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '=') {
            $parts = $line -split '=', 2
            $facts[$parts[0]] = $parts[1]
        }
    }
    return $facts
}

function Resolve-GatewayConfig {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$State
    )

    $savedGatewayBaseUrl = if ($State.Contains('gatewayBaseUrl')) { [string]$State['gatewayBaseUrl'] } else { '' }
    $savedGatewayId = if ($State.Contains('gatewayId')) { [string]$State['gatewayId'] } else { '' }
    $savedGatewaySharedSecret = if ($State.Contains('gatewaySharedSecret')) { [string]$State['gatewaySharedSecret'] } else { '' }
    $preferredGatewayBaseUrl = if ($GatewayBaseUrl) { $GatewayBaseUrl } else { '' }
    $useSavedGatewayCredentials = ($savedGatewayBaseUrl -and $preferredGatewayBaseUrl -and ($savedGatewayBaseUrl.TrimEnd('/') -eq $preferredGatewayBaseUrl.TrimEnd('/'))) -or
      (-not $preferredGatewayBaseUrl)

    $script:ResolvedGatewayBaseUrl = if ($GatewayBaseUrl) {
        $GatewayBaseUrl
    } elseif ($savedGatewayBaseUrl) {
        $savedGatewayBaseUrl
    } else {
        'http://bedjet-gateway.local'
    }

    $script:ResolvedGatewayId = if ($GatewayId) {
        $GatewayId
    } elseif ($useSavedGatewayCredentials -and $savedGatewayId) {
        $savedGatewayId
    } else {
        'bedjet-bridge'
    }

    $script:ResolvedGatewaySharedSecret = if ($GatewaySharedSecret) {
        $GatewaySharedSecret
    } elseif ($useSavedGatewayCredentials -and $savedGatewaySharedSecret) {
        $savedGatewaySharedSecret
    } else {
        $secretBytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try {
            $rng.GetBytes($secretBytes)
        }
        finally {
            $rng.Dispose()
        }
        ([System.BitConverter]::ToString($secretBytes)).Replace('-', '').ToLowerInvariant()
    }
}

function Resolve-SshTarget {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$State,

        [Parameter()]
        [string]$ProvidedTarget,

        [Parameter()]
        [switch]$RemoteSkipped
    )

    if ($RemoteSkipped) {
        return ''
    }

    $candidate = $ProvidedTarget.Trim()
    if (-not $candidate -and $State.Contains('sshTarget') -and $State['sshTarget']) {
        $candidate = [string]$State['sshTarget']
    }
    $candidate = $candidate.Trim()
    if (-not $candidate) {
        throw 'SSH target is required for remote steps. Pass -SshTarget user@host (or run once with -SshTarget so it is saved in data/setup-state.json).'
    }

    return $candidate
}

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter()]
        [object]$Body,

        [Parameter()]
        [hashtable]$Headers = @{},

        [Parameter()]
        [switch]$AllowFailure
    )

    $requestParams = @{
        Method      = $Method
        Uri         = $Uri
        TimeoutSec  = 5
        Headers     = $Headers
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $requestParams.ContentType = 'application/json'
        $requestParams.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }

    try {
        return Invoke-RestMethod @requestParams
    }
    catch {
        if ($AllowFailure) {
            return $null
        }
        throw
    }
}

function Resolve-GatewayBaseUrl {
    param(
        [Parameter(Mandatory)]
        [string]$PreferredBaseUrl
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($PreferredBaseUrl) {
        $candidates.Add($PreferredBaseUrl.TrimEnd('/'))
    }
    foreach ($candidate in @('http://bedjet-gateway.local', 'http://bedjet-gateway')) {
        if (-not $candidates.Contains($candidate)) {
            $candidates.Add($candidate)
        }
    }

    foreach ($candidate in $candidates) {
        $health = Invoke-JsonRequest -Method 'GET' -Uri ($candidate + '/healthz') -AllowFailure
        if ($health -and $health.ok) {
            return $candidate
        }
    }

    throw 'Gateway was not reachable on the local LAN. Re-run with -GatewayBaseUrl http://<gateway-ip>.'
}

function Resolve-GatewayRemoteBaseUrl {
    param(
        [Parameter(Mandatory)]
        [string]$LocalBaseUrl
    )

    $health = Invoke-JsonRequest -Method 'GET' -Uri ($LocalBaseUrl + '/healthz')
    $stationIp = ''
    if ($health -and $health.network -and $health.network.stationIp) {
        $stationIp = [string]$health.network.stationIp
    }

    if ($stationIp) {
        return "http://$stationIp"
    }

    return $LocalBaseUrl
}

function Get-UriHost {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    return ([System.Uri]$Uri).Host
}

function Resolve-SmartThingsBridgeHost {
    param(
        [Parameter(Mandatory)]
        [hashtable]$RemoteFacts,

        [Parameter(Mandatory)]
        [int]$Port
    )

    $candidates = [System.Collections.Generic.List[string]]::new()

    if ($RemoteFacts.ContainsKey('host_fqdn') -and $RemoteFacts['host_fqdn']) {
        [void]$candidates.Add([string]$RemoteFacts['host_fqdn'])
        $short = ([string]$RemoteFacts['host_fqdn']).Split('.')[0]
        if ($short) {
            [void]$candidates.Add("$short.local")
        }
    }

    if ($RemoteFacts.ContainsKey('lan_ip') -and $RemoteFacts['lan_ip']) {
        [void]$candidates.Add([string]$RemoteFacts['lan_ip'])
    }

    $deduped = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        if ($candidate -and -not $deduped.Contains($candidate)) {
            [void]$deduped.Add($candidate)
        }
    }

    foreach ($candidate in $deduped) {
        $health = Invoke-JsonRequest -Method 'GET' -Uri "http://$candidate`:$Port/healthz" -AllowFailure
        if ($health -and $health.ok) {
            return @{
                Host = $candidate
                Source = 'probed'
            }
        }
    }

    if ($RemoteFacts.ContainsKey('lan_ip') -and $RemoteFacts['lan_ip']) {
        return @{
            Host = [string]$RemoteFacts['lan_ip']
            Source = 'fallback-lan-ip'
        }
    }

    throw 'Unable to determine SmartThings bridge host target from remote facts.'
}

function Get-HmacSignature {
    param(
        [Parameter(Mandatory)]
        [string]$Secret,

        [Parameter(Mandatory)]
        [string]$Message
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
        [Parameter(Mandatory)]
        [string]$GatewayId,

        [Parameter(Mandatory)]
        [string]$SharedSecret,

        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [string]$Body = ''
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
    $message = ($Method.ToUpperInvariant(), $Path, $Body, $timestamp, $nonce) -join "`n"
    $signature = Get-HmacSignature -Secret $SharedSecret -Message $message

    return @{
        'X-Gateway-Id' = $GatewayId
        'X-Timestamp'  = $timestamp
        'X-Nonce'      = $nonce
        'X-Signature'  = $signature
    }
}

function Ensure-GatewayClaimed {
    $claimStatus = Invoke-JsonRequest -Method 'GET' -Uri ($script:ResolvedGatewayBaseUrl + '/api/v1/claim/status')

    if (-not $claimStatus.claimed) {
        $payload = @{
            gatewayId = $script:ResolvedGatewayId
            sharedSecret = $script:ResolvedGatewaySharedSecret
        }
        $claimResult = Invoke-JsonRequest -Method 'POST' -Uri ($script:ResolvedGatewayBaseUrl + '/api/v1/claim') -Body $payload
        if (-not $claimResult.ok) {
            throw 'Gateway claim did not succeed.'
        }
        Write-Ok "Gateway claimed as $($script:ResolvedGatewayId)"
        return
    }

    if ($claimStatus.gatewayId -ne $script:ResolvedGatewayId) {
        throw "Gateway is already claimed by $($claimStatus.gatewayId). Reset the gateway or rerun with the matching -GatewayId and -GatewaySharedSecret."
    }

    Write-Ok "Gateway already claimed as $($claimStatus.gatewayId)"
}

function Test-GatewaySignedAccess {
    $path = '/api/v1/state'
    $headers = New-SignedHeaders -GatewayId $script:ResolvedGatewayId -SharedSecret $script:ResolvedGatewaySharedSecret -Method 'GET' -Path $path
    $state = Invoke-JsonRequest -Method 'GET' -Uri ($script:ResolvedGatewayBaseUrl + $path) -Headers $headers
    if (-not $state.sides) {
        throw 'Signed gateway verification failed.'
    }
}

function Write-BridgeEnvFile {
    $envPath = Join-Path $BundleRoot 'deploy\bridge\bridge.env'
    $content = @(
        'HOST=0.0.0.0'
        "PORT=$BridgePort"
        'TIMEZONE=America/Los_Angeles'
        'DATA_PATH=/app/data/bridge.sqlite'
        "FIRMWARE_API_BASE_URL=$script:ResolvedGatewayRemoteBaseUrl"
        "FIRMWARE_GATEWAY_ID=$script:ResolvedGatewayId"
        "FIRMWARE_SHARED_SECRET=$script:ResolvedGatewaySharedSecret"
        'SIMULATE_FIRMWARE=false'
        'SCHEDULER_INTERVAL_MS=30000'
    ) -join "`r`n"
    Set-Content -Path $envPath -Value $content
}

function New-DeployBundle {
    if (Test-Path $StageRoot) {
        Remove-Item $StageRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $BundleRoot | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $BundleRoot 'deploy') | Out-Null
    Copy-Item $BridgeRoot -Destination (Join-Path $BundleRoot 'bridge') -Recurse
    Copy-Item $DeployRoot -Destination (Join-Path $BundleRoot 'deploy\bridge') -Recurse
    Write-BridgeEnvFile

    $tar = Get-NativeCommand -Name 'tar'
    Invoke-Native -FilePath $tar -ArgumentList @(
        '-C', $BundleRoot,
        '-czf', $ArchivePath,
        '.'
    ) | Out-Null

    return $ArchivePath
}

function Install-RemoteBridge {
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [string]$RemoteInstallDir
    )

    $archive = New-DeployBundle
    $remoteArchive = "$RemoteInstallDir/bedjet-bridge-bundle.tgz"
    $remoteRelativeInstallDir = ($RemoteInstallDir -replace '^~/', '')
    $remoteResolvedInstallDir = '$HOME/' + $remoteRelativeInstallDir

    Invoke-Ssh -ArgumentList @('-o', 'BatchMode=yes', $Target, "mkdir -p $RemoteInstallDir") | Out-Null
    Invoke-Scp -ArgumentList @($archive, "${Target}:${remoteArchive}") | Out-Null

    $remoteScript = @(
        'set -euo pipefail',
        "cd ""$remoteResolvedInstallDir""",
        "tar -xzf 'bedjet-bridge-bundle.tgz'",
        "bash deploy/bridge/install-bridge-remote.sh --install-dir ""$remoteResolvedInstallDir"""
    ) -join ' && '

    Invoke-Ssh -ArgumentList @(
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=8',
        $Target,
        'bash',
        '-lc',
        $remoteScript
    ) | Out-Null
}

function Test-RemoteBridgeHealth {
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [int]$Port
    )

    [void](Wait-RemoteHttpGet -Target $Target -Url "http://127.0.0.1:$Port/healthz")
}

function Test-RemoteBridgeGatewayIntegration {
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [Parameter(Mandatory)]
        [int]$Port
    )

    $result = Wait-RemoteHttpGet -Target $Target -Url "http://127.0.0.1:$Port/v1/system"

    $snapshot = $result.Output | ConvertFrom-Json
    if (-not $snapshot.gatewayClaim.claimed) {
        throw 'Bridge can reach the gateway, but the gateway is not claimed.'
    }
    if (-not $snapshot.gatewayState.claim.claimed) {
        throw 'Bridge system snapshot did not report the claimed gateway state.'
    }
}

$state = Get-SetupState
Resolve-GatewayConfig -State $state
$script:ResolvedSshTarget = Resolve-SshTarget -State $state -ProvidedTarget $SshTarget -RemoteSkipped:$SkipRemote

Write-Step 'Step 1: local prerequisites'
$checks = @(
    (Test-CommandVersion -Name 'ssh' -VersionArgs @('-V')),
    (Test-CommandVersion -Name 'scp' -VersionArgs @('-V')),
    (Test-CommandVersion -Name 'tar' -VersionArgs @('--version'))
)
$checks | ForEach-Object {
    Write-Ok ("{0}: {1}" -f $_.Name, $_.Path)
}

if (-not $SkipRemote -and -not (Confirm-Step -Prompt "Use SSH target $($script:ResolvedSshTarget)")) {
    throw 'Aborted by user.'
}

if (-not $SkipRemote) {
    Write-Step 'Step 2: SSH batch-mode check'
    Test-SshBatchMode -Target $script:ResolvedSshTarget
    Write-Ok "SSH batch mode works for $($script:ResolvedSshTarget)"
} else {
    Write-Step 'Step 2: remote checks skipped'
    $script:ResolvedBridgeLanUrl = "http://127.0.0.1:$BridgePort"
    Write-Ok 'Skipped SSH, remote LAN, and Docker checks'
}

Write-Step 'Step 3: local gateway discovery'
$script:ResolvedGatewayBaseUrl = Resolve-GatewayBaseUrl -PreferredBaseUrl $script:ResolvedGatewayBaseUrl
$script:ResolvedGatewayRemoteBaseUrl = Resolve-GatewayRemoteBaseUrl -LocalBaseUrl $script:ResolvedGatewayBaseUrl
Write-Ok "Gateway reachable at $($script:ResolvedGatewayBaseUrl)"
if ($script:ResolvedGatewayRemoteBaseUrl -ne $script:ResolvedGatewayBaseUrl) {
    Write-Ok "Remote bridge will use gateway URL $($script:ResolvedGatewayRemoteBaseUrl)"
}

Write-Step 'Step 4: gateway claim and signed verification'
Ensure-GatewayClaimed
Test-GatewaySignedAccess
Write-Ok 'Signed gateway requests work'

if (-not $SkipRemote) {
    Write-Step 'Step 5: remote host network and Docker check'
    $remoteFacts = Get-RemoteFacts -Target $script:ResolvedSshTarget -GatewayIp (Get-UriHost -Uri $script:ResolvedGatewayRemoteBaseUrl)
    if (-not $remoteFacts['lan_ip']) {
        throw 'Remote host does not expose a LAN IPv4 address that can reach the gateway.'
    }
    if ($remoteFacts['has_docker'] -ne '1') {
        throw 'Docker is not installed on the remote host.'
    }
    if ($remoteFacts['daemon_usable'] -ne '1') {
        throw 'Docker is installed but not usable by the remote user.'
    }
    if ($remoteFacts['compose_available'] -ne '1') {
        throw 'docker compose is not available on the remote host.'
    }
    $script:ResolvedBridgeLanUrl = "http://$($remoteFacts['lan_ip']):$BridgePort"
    $smartThingsBridge = Resolve-SmartThingsBridgeHost -RemoteFacts $remoteFacts -Port $BridgePort
    $script:ResolvedSmartThingsBridgeHost = $smartThingsBridge.Host
    Write-Ok "Remote LAN IP: $($remoteFacts['lan_ip'])"
    if ($remoteFacts['host_fqdn']) {
        Write-Ok "Remote host FQDN: $($remoteFacts['host_fqdn'])"
    }
    if ($remoteFacts['tailscale_ip']) {
        Write-Ok "Remote Tailscale IP: $($remoteFacts['tailscale_ip'])"
    }
    Write-Ok "SmartThings bridge host target: $($script:ResolvedSmartThingsBridgeHost) [$($smartThingsBridge.Source)]"
    Write-Ok 'Remote Docker looks healthy'
} else {
    $script:ResolvedSmartThingsBridgeHost = '127.0.0.1'
}

if ($script:ResolvedSshTarget) {
    $state['sshTarget'] = $script:ResolvedSshTarget
}
$state['gatewayBaseUrl'] = $script:ResolvedGatewayBaseUrl
$state['gatewayRemoteBaseUrl'] = $script:ResolvedGatewayRemoteBaseUrl
$state['gatewayId'] = $script:ResolvedGatewayId
$state['gatewaySharedSecret'] = $script:ResolvedGatewaySharedSecret
$state['bridgeLanUrl'] = $script:ResolvedBridgeLanUrl
$state['smartThingsBridgeHost'] = $script:ResolvedSmartThingsBridgeHost
$state['bridgePort'] = $BridgePort
$state['updatedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
Save-SetupState -State $state
Write-Ok "Saved setup state to $SetupStatePath"

if (-not $SkipDeploy -and -not $SkipRemote) {
    if (-not (Confirm-Step -Prompt "Deploy the bridge to $($script:ResolvedSshTarget) at $InstallDir")) {
        throw 'Aborted by user.'
    }

    Write-Step 'Step 6: deploy bridge bundle'
    Install-RemoteBridge -Target $script:ResolvedSshTarget -RemoteInstallDir $InstallDir
    Write-Ok 'Remote deploy completed'

    Write-Step 'Step 7: verify bridge health'
    Test-RemoteBridgeHealth -Target $script:ResolvedSshTarget -Port $BridgePort
    Write-Ok 'Remote bridge health check passed'

    Write-Step 'Step 8: verify bridge-to-gateway integration'
    Test-RemoteBridgeGatewayIntegration -Target $script:ResolvedSshTarget -Port $BridgePort
    Write-Ok 'Bridge can talk to the claimed gateway'
} elseif ($SkipRemote) {
    Write-Step 'Step 6: remote deploy skipped'
    Write-Ok 'Skipped bridge deploy and remote verification for local dry run'
}

Write-Host ''
Write-Host '[ok] Setup script finished' -ForegroundColor Green
Write-Host ("[ok] SmartThings bridge URL: {0}" -f $script:ResolvedBridgeLanUrl) -ForegroundColor Green
Write-Host ("[ok] SmartThings driver host: {0}" -f $script:ResolvedSmartThingsBridgeHost) -ForegroundColor Green
Write-Host ("[ok] SmartThings driver port: {0}" -f $BridgePort) -ForegroundColor Green
Write-Host ("[ok] Gateway URL: {0}" -f $script:ResolvedGatewayBaseUrl) -ForegroundColor Green
