[CmdletBinding()]
param(
	[string]$GatewayBaseUrl = '',
	[string]$BridgeBaseUrl = '',
	[int]$ReadIterations = 60,
	[int]$VerifyIterations = 20,
	[int]$ReadThrottle = 24,
	[int]$VerifyThrottle = 6,
	[int]$TimeoutSecRead = 10,
	[int]$TimeoutSecVerify = 15,
	[string]$OutputPath = 'data/stress-test-latest.json'
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

function Resolve-BaseUrl {
	param(
		[string]$Provided,
		[System.Collections.IDictionary]$State,
		[string]$StateKey,
		[string]$Name
	)

	$candidate = ''
	if ($null -ne $Provided) {
		$candidate = [string]$Provided
	}
	$candidate = $candidate.Trim()
	if (-not $candidate -and $State.Contains($StateKey) -and $State[$StateKey]) {
		$candidate = ([string]$State[$StateKey]).Trim()
	}
	if (-not $candidate) {
		throw "$Name is required. Provide parameter or ensure $StateKey exists in data/setup-state.json."
	}
	return $candidate.TrimEnd('/')
}

function Get-Percentile {
	param(
		$Values,
		[double]$Percent
	)

	$arrayValues = @($Values)
	if ($arrayValues.Count -eq 0) {
		return 0
	}

	$sorted = @($arrayValues | Sort-Object)
	$index = [int][math]::Floor(($sorted.Count - 1) * $Percent)
	return [int]$sorted[$index]
}

function Expand-Requests {
	param(
		[array]$Specs,
		[int]$Iterations
	)

	$requests = @()
	foreach ($spec in $Specs) {
		for ($i = 0; $i -lt $Iterations; $i++) {
			$requests += [pscustomobject]@{
				name = $spec.name
				method = $spec.method
				url = $spec.url
				body = $spec.body
			}
		}
	}
	return $requests
}

function Invoke-StressPhase {
	param(
		[string]$Name,
		[array]$Requests,
		[int]$Throttle,
		[int]$TimeoutSec
	)

	$results = New-Object System.Collections.Generic.List[object]
	$runningJobs = @()
	$queue = New-Object System.Collections.Queue
	foreach ($request in $Requests) {
		$queue.Enqueue($request)
	}

	$worker = {
		param($Request, $TimeoutSecInner)
		$sw = [System.Diagnostics.Stopwatch]::StartNew()
		$ok = $false
		$status = 0
		$errorText = ''
		try {
			if ($Request.method -eq 'GET') {
				$response = Invoke-WebRequest -Method Get -Uri $Request.url -TimeoutSec $TimeoutSecInner -UseBasicParsing
			} else {
				$bodyJson = if ($Request.body) { ($Request.body | ConvertTo-Json -Compress) } else { '{}' }
				$response = Invoke-WebRequest -Method Post -Uri $Request.url -TimeoutSec $TimeoutSecInner -UseBasicParsing -ContentType 'application/json' -Body $bodyJson
			}
			$status = [int]$response.StatusCode
			$ok = $status -ge 200 -and $status -lt 300
		} catch {
			$statusCode = $_.Exception.Response.StatusCode.value__ 2>$null
			if ($statusCode) {
				$status = [int]$statusCode
			}
			$errorText = $_.Exception.Message
		}
		$sw.Stop()
		[pscustomobject]@{
			name = $Request.name
			method = $Request.method
			url = $Request.url
			ok = $ok
			status = $status
			latencyMs = [int]$sw.ElapsedMilliseconds
			error = $errorText
		}
	}

	while ($queue.Count -gt 0 -or $runningJobs.Count -gt 0) {
		while ($queue.Count -gt 0 -and $runningJobs.Count -lt $Throttle) {
			$nextRequest = $queue.Dequeue()
			$job = Start-Job -ScriptBlock $worker -ArgumentList @($nextRequest, $TimeoutSec)
			$runningJobs += $job
		}

		if ($runningJobs.Count -eq 0) {
			continue
		}

		$completed = Wait-Job -Job $runningJobs -Any -Timeout 30
		if ($null -eq $completed) {
			continue
		}

		$completedJobs = @($completed)
		foreach ($doneJob in $completedJobs) {
			$completedResults = Receive-Job -Job $doneJob -ErrorAction SilentlyContinue
			foreach ($row in @($completedResults)) {
				[void]$results.Add($row)
			}
			Remove-Job -Job $doneJob -Force
		}

		$doneIds = @($completedJobs | Select-Object -ExpandProperty Id)
		$runningJobs = @($runningJobs | Where-Object { $doneIds -notcontains $_.Id })
	}

	$rows = @($results.ToArray() | Where-Object { $_ -and $_.PSObject.Properties['name'] -and $_.PSObject.Properties['latencyMs'] -and $_.PSObject.Properties['ok'] })
	$latencies = @($rows | Select-Object -ExpandProperty latencyMs)
	$failed = @($rows | Where-Object { -not $_.ok })

	$endpointStats = @()
	$groupedRows = @($rows | Group-Object -Property name)
	foreach ($grouping in $groupedRows) {
		$group = @($grouping.Group)
		$groupCount = @($group).Count
		$groupFailures = @($group | Where-Object { -not $_.ok }).Count
		$groupLat = @($group | Select-Object -ExpandProperty latencyMs)
		$endpointStats += [pscustomobject]@{
			endpoint = $grouping.Name
			total = $groupCount
			failed = $groupFailures
			successRate = if ($groupCount -gt 0) { [math]::Round((($groupCount - $groupFailures) / $groupCount) * 100, 2) } else { 0 }
			p95Ms = Get-Percentile -Values $groupLat -Percent 0.95
			maxMs = if ($groupLat.Count -gt 0) { ($groupLat | Measure-Object -Maximum).Maximum } else { 0 }
		}
	}

	[pscustomobject]@{
		name = $Name
		total = $rows.Count
		failed = $failed.Count
		successRate = if ($rows.Count -gt 0) { [math]::Round((($rows.Count - $failed.Count) / $rows.Count) * 100, 2) } else { 0 }
		p50Ms = Get-Percentile -Values $latencies -Percent 0.50
		p95Ms = Get-Percentile -Values $latencies -Percent 0.95
		p99Ms = Get-Percentile -Values $latencies -Percent 0.99
		maxMs = if ($latencies.Count -gt 0) { ($latencies | Measure-Object -Maximum).Maximum } else { 0 }
		endpoints = $endpointStats
		sampleErrors = @($failed | Select-Object -First 5 name,status,error)
	}
}

$state = Get-SetupState
$resolvedGateway = Resolve-BaseUrl -Provided $GatewayBaseUrl -State $state -StateKey 'gatewayBaseUrl' -Name 'GatewayBaseUrl'
$resolvedBridge = Resolve-BaseUrl -Provided $BridgeBaseUrl -State $state -StateKey 'bridgeLanUrl' -Name 'BridgeBaseUrl'

Write-Host "Gateway: $resolvedGateway"
Write-Host "Bridge:  $resolvedBridge"

$baselineRequests = @(
	[pscustomobject]@{ name = 'gateway-healthz'; method = 'GET'; url = "$resolvedGateway/healthz"; body = $null },
	[pscustomobject]@{ name = 'gateway-version'; method = 'GET'; url = "$resolvedGateway/api/v1/version"; body = $null },
	[pscustomobject]@{ name = 'gateway-local-status'; method = 'GET'; url = "$resolvedGateway/api/v1/local/status"; body = $null },
	[pscustomobject]@{ name = 'bridge-healthz'; method = 'GET'; url = "$resolvedBridge/healthz"; body = $null },
	[pscustomobject]@{ name = 'bridge-readyz'; method = 'GET'; url = "$resolvedBridge/readyz"; body = $null },
	[pscustomobject]@{ name = 'bridge-version'; method = 'GET'; url = "$resolvedBridge/v1/version"; body = $null },
	[pscustomobject]@{ name = 'bridge-system'; method = 'GET'; url = "$resolvedBridge/v1/system"; body = $null }
)

$readSpecs = @(
	[pscustomobject]@{ name = 'gateway-healthz'; method = 'GET'; url = "$resolvedGateway/healthz"; body = $null },
	[pscustomobject]@{ name = 'gateway-version'; method = 'GET'; url = "$resolvedGateway/api/v1/version"; body = $null },
	[pscustomobject]@{ name = 'bridge-healthz'; method = 'GET'; url = "$resolvedBridge/healthz"; body = $null },
	[pscustomobject]@{ name = 'bridge-system'; method = 'GET'; url = "$resolvedBridge/v1/system"; body = $null }
)

$verifySpecs = @(
	[pscustomobject]@{ name = 'bridge-verify-left'; method = 'POST'; url = "$resolvedBridge/v1/bedjets/left/verify"; body = @{} },
	[pscustomobject]@{ name = 'bridge-verify-right'; method = 'POST'; url = "$resolvedBridge/v1/bedjets/right/verify"; body = @{} }
)

Write-Host "Running phase: baseline"
$phaseBaseline = Invoke-StressPhase -Name 'baseline' -Requests $baselineRequests -Throttle 2 -TimeoutSec $TimeoutSecRead

Write-Host "Running phase: read-stress"
$phaseRead = Invoke-StressPhase -Name 'read-stress' -Requests (Expand-Requests -Specs $readSpecs -Iterations $ReadIterations) -Throttle $ReadThrottle -TimeoutSec $TimeoutSecRead

Write-Host "Running phase: verify-stress"
$phaseVerify = Invoke-StressPhase -Name 'verify-stress' -Requests (Expand-Requests -Specs $verifySpecs -Iterations $VerifyIterations) -Throttle $VerifyThrottle -TimeoutSec $TimeoutSecVerify

$summary = [pscustomobject]@{
	generatedAt = (Get-Date).ToString('o')
	gateway = $resolvedGateway
	bridge = $resolvedBridge
	settings = [pscustomobject]@{
		readIterations = $ReadIterations
		verifyIterations = $VerifyIterations
		readThrottle = $ReadThrottle
		verifyThrottle = $VerifyThrottle
		timeoutSecRead = $TimeoutSecRead
		timeoutSecVerify = $TimeoutSecVerify
	}
	phases = @($phaseBaseline, $phaseRead, $phaseVerify)
}

$outputAbsolute = Join-Path $RepoRoot $OutputPath
$outputDir = Split-Path -Parent $outputAbsolute
if (-not (Test-Path $outputDir)) {
	New-Item -Path $outputDir -ItemType Directory | Out-Null
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -Path $outputAbsolute
Write-Host "Stress summary written to $outputAbsolute"
$summary | ConvertTo-Json -Depth 8
