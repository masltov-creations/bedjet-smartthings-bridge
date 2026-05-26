# Firmware Post-Flash API Verification Script (Windows PowerShell)
# Validates that core gateway endpoints are reachable after firmware deployment.

param(
    [string]$BaseUrl = "http://192.168.1.11",
    [int]$TimeoutSeconds = 8,
    [switch]$RunConcurrencyProbe = $false,
    [int]$ConcurrencyRequests = 12
)

$ErrorActionPreference = "Stop"

$tests = @(
    @{ Name = "Health"; Method = "GET"; Path = "/healthz"; Expect = { param($r) $r.ok -eq $true } },
    @{ Name = "Version"; Method = "GET"; Path = "/api/v1/version"; Expect = { param($r) $r.ok -eq $true -and $null -ne $r.firmware } },
    @{ Name = "Provision Status"; Method = "GET"; Path = "/api/v1/provision/status"; Expect = { param($r) $null -ne $r } },
    @{ Name = "Local Status"; Method = "GET"; Path = "/api/v1/local/status"; Expect = { param($r) $r.ok -eq $true } },
    @{ Name = "Local Scan"; Method = "GET"; Path = "/api/v1/local/scan"; Expect = { param($r) $null -ne $r.devices } },
    @{ Name = "Local Settings (No-op Save)"; Method = "POST"; Path = "/api/v1/local/settings"; Body = @{ pollIntervalSeconds = 15 }; Expect = { param($r) $r.ok -eq $true } }
)

$passed = 0
$failed = 0

Write-Host ""
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "Firmware Endpoint Verification" -ForegroundColor Cyan
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "Target: $BaseUrl"
Write-Host ""

foreach ($test in $tests) {
    $url = "$BaseUrl$($test.Path)"
    try {
        if ($test.Method -eq "GET") {
            $resp = Invoke-RestMethod -Method Get -Uri $url -TimeoutSec $TimeoutSeconds
        } else {
            $jsonBody = ($test.Body | ConvertTo-Json -Depth 4 -Compress)
            $resp = Invoke-RestMethod -Method Post -Uri $url -TimeoutSec $TimeoutSeconds -ContentType "application/json" -Body $jsonBody
        }

        if (& $test.Expect $resp) {
            Write-Host "PASS $($test.Name)" -ForegroundColor Green
            $passed++
        } else {
            Write-Host "FAIL $($test.Name): Unexpected response contract" -ForegroundColor Red
            $failed++
        }
    } catch {
        Write-Host "FAIL $($test.Name): $($_.Exception.Message)" -ForegroundColor Red
        $failed++
    }
}

if ($RunConcurrencyProbe) {
    Write-Host ""
    Write-Host "[PROBE] Concurrency check with $ConcurrencyRequests lightweight requests" -ForegroundColor Yellow

    $jobs = @()
    for ($i = 0; $i -lt $ConcurrencyRequests; $i++) {
        $path = if ($i % 2 -eq 0) { "/healthz" } else { "/api/v1/version" }
        $jobs += Start-Job -ScriptBlock {
            param($url, $timeout)
            try {
                Invoke-RestMethod -Method Get -Uri $url -TimeoutSec $timeout | Out-Null
                return $true
            } catch {
                return $false
            }
        } -ArgumentList "$BaseUrl$path", $TimeoutSeconds
    }

    $results = $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job -Force | Out-Null

    $successCount = ($results | Where-Object { $_ -eq $true }).Count
    if ($successCount -eq $ConcurrencyRequests) {
        Write-Host "PASS Concurrency probe ($successCount/$ConcurrencyRequests)" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "FAIL Concurrency probe ($successCount/$ConcurrencyRequests)" -ForegroundColor Red
        $failed++
    }
}

Write-Host ""
Write-Host "==========================================="
Write-Host "Passed: $passed"
Write-Host "Failed: $failed"
Write-Host "==========================================="

if ($failed -gt 0) {
    exit 1
}

Write-Host "All endpoint checks passed." -ForegroundColor Green
