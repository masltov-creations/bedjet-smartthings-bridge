[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChannelId,

    [Parameter(Mandatory = $true)]
    [string]$HubId,

    [string]$BridgeHost = '',
    [string]$BridgeFallbackIp = '',
    [int]$BridgePort = 8787,

    [string]$RepoRoot = '',

    [string]$XdgStateHome = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
$SetupStatePath = Join-Path $RepoRoot 'data\setup-state.json'
$DriverDir = Join-Path $RepoRoot 'smartthings-edge'

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

function Resolve-BridgeHost {
    param([System.Collections.IDictionary]$State)

    $value = ''
    if ($null -ne $BridgeHost) {
        $value = [string]$BridgeHost
    }
    $value = $value.Trim()
    if (-not $value -and $State.Contains('smartThingsBridgeHost')) {
        $value = [string]$State['smartThingsBridgeHost']
    }
    if (-not $value -and $State.Contains('bridgeLanUrl') -and $State['bridgeLanUrl']) {
        try {
            $uri = [Uri]([string]$State['bridgeLanUrl'])
            $value = $uri.Host
        } catch {
        }
    }
    if ($null -eq $value) {
        $value = ''
    }
    $value = ([string]$value).Trim()
    if (-not $value) {
        throw 'BridgeHost is required. Pass -BridgeHost or ensure setup-state contains smartThingsBridgeHost/bridgeLanUrl.'
    }
    return $value
}

function Resolve-BridgeFallbackIp {
    param([System.Collections.IDictionary]$State)

    $value = ''
    if ($null -ne $BridgeFallbackIp) {
        $value = [string]$BridgeFallbackIp
    }
    $value = $value.Trim()
    if (-not $value -and $State.Contains('smartThingsBridgeFallbackIp')) {
        $value = [string]$State['smartThingsBridgeFallbackIp']
    }
    if (-not $value -and $State.Contains('bridgeLanUrl') -and $State['bridgeLanUrl']) {
        try {
            $uri = [Uri]([string]$State['bridgeLanUrl'])
            if ($uri.Host -match '^\d+\.\d+\.\d+\.\d+$') {
                $value = $uri.Host
            }
        } catch {
        }
    }
    if ($null -eq $value) {
        $value = ''
    }
    return ([string]$value).Trim()
}

function Assert-Dependency {
    param([string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Update-ProfileDefaults {
    param(
        [string]$ProfilePath,
        [string]$ResolvedHost,
        [int]$ResolvedPort,
        [string]$ResolvedFallbackIp
    )

    $content = Get-Content -Path $ProfilePath -Raw

    $content = [regex]::Replace(
        $content,
        '(?m)^(\s*default:\s*)(?:bedjet-bridge\.local|bridge-host-or-ip)\s*$',
        {
            param($m)
            return $m.Groups[1].Value + $ResolvedHost
        }
    )

    $content = [regex]::Replace(
        $content,
        '(?m)^(\s*name:\s*bridgePort\s*\r?\n(?:.*\r?\n)*?\s*default:\s*)8787\s*$',
        {
            param($m)
            return $m.Groups[1].Value + [string]$ResolvedPort
        }
    )

    if ($ResolvedFallbackIp) {
        $content = [regex]::Replace(
            $content,
            '(?m)^(\s*name:\s*bridgeFallbackIp\s*\r?\n(?:.*\r?\n)*?\s*default:\s*)""\s*$',
            {
                param($m)
                return $m.Groups[1].Value + '"' + $ResolvedFallbackIp + '"'
            }
        )
    }

    Set-Content -Path $ProfilePath -Value $content
}

function Assert-ProfileInjected {
    param(
        [string]$ProfilePath,
        [string]$ResolvedHost
    )

    $content = Get-Content -Path $ProfilePath -Raw
    if ($content -match 'default:\s*bridge-host-or-ip') {
        throw "Profile still contains placeholder host in $ProfilePath"
    }
    if ($content -notmatch [regex]::Escape("default: $ResolvedHost")) {
        throw "Profile injection check failed for host in $ProfilePath"
    }
}

Assert-Dependency -Name 'smartthings'

$state = Get-SetupState
$resolvedBridgeHost = Resolve-BridgeHost -State $state
$resolvedBridgeFallbackIp = Resolve-BridgeFallbackIp -State $state

if ($BridgePort -lt 1 -or $BridgePort -gt 65535) {
    throw "Invalid BridgePort value: $BridgePort"
}

$tempRoot = Join-Path $env:TEMP ("bedjet-edge-configured-" + [Guid]::NewGuid().ToString('N'))
$tempDriver = Join-Path $tempRoot 'smartthings-edge'

New-Item -Path $tempDriver -ItemType Directory -Force | Out-Null
Copy-Item -Path (Join-Path $DriverDir '*') -Destination $tempDriver -Recurse -Force

$profilePaths = @(
    (Join-Path $tempDriver 'profiles\bedjet-unit.v1.yaml'),
    (Join-Path $tempDriver 'profiles\bedjet-nightly-bio.v1.yaml')
)

foreach ($profile in $profilePaths) {
    Update-ProfileDefaults -ProfilePath $profile -ResolvedHost $resolvedBridgeHost -ResolvedPort $BridgePort -ResolvedFallbackIp $resolvedBridgeFallbackIp
    Assert-ProfileInjected -ProfilePath $profile -ResolvedHost $resolvedBridgeHost
}

Write-Host ("Packaging configured Edge driver with bridgeHost={0} bridgeFallbackIp={1} bridgePort={2}" -f $resolvedBridgeHost, ($(if ($resolvedBridgeFallbackIp) { $resolvedBridgeFallbackIp } else { '<empty>' })), $BridgePort)

$args = @('edge:drivers:package', $tempDriver, '--channel', $ChannelId, '--hub', $HubId)
if ($XdgStateHome) {
    $env:XDG_STATE_HOME = $XdgStateHome
}

& smartthings @args
if ($LASTEXITCODE -ne 0) {
    throw "smartthings edge:drivers:package failed with exit code $LASTEXITCODE"
}

Write-Host ("[ok] Driver installed to hub {0} from channel {1}" -f $HubId, $ChannelId) -ForegroundColor Green
