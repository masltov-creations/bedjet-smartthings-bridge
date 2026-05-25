# Firmware Integration Test Validation Script (Windows PowerShell)
# Runs smoke tests at each phase to catch compilation and basic contract errors

param(
    [switch]$SkipBuild = $false,
    [switch]$Verbose = $false
)

$ErrorActionPreference = "Stop"

$FirmwareDir = Split-Path -Parent $PSScriptRoot
$ProjectRoot = Split-Path -Parent $FirmwareDir

Write-Host ""
Write-Host "===========================================" -ForegroundColor Cyan
Write-Host "Firmware Integration Test Validation" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# Test 1: Verify PlatformIO is installed
Write-Host "[TEST 1] Checking PlatformIO installation" -ForegroundColor Yellow
try {
    $PioVersion = & platformio --version 2>&1
    Write-Host "✓ PlatformIO found: $PioVersion" -ForegroundColor Green
} catch {
    Write-Host "✗ PlatformIO not found. Install with: pip install platformio" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test 2: Compile firmware (with simulated backend)
if (-not $SkipBuild) {
    Write-Host "[TEST 2] Compiling firmware with simulated backend" -ForegroundColor Yellow
    Push-Location $FirmwareDir
    try {
        $BuildOutput = & platformio run -e esp32-s3-devkitc-1 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Compilation successful" -ForegroundColor Green
            if ($Verbose) {
                Write-Host $BuildOutput
            }
        } else {
            Write-Host "✗ Compilation failed" -ForegroundColor Red
            Write-Host $BuildOutput
            exit 1
        }
    } finally {
        Pop-Location
    }
    Write-Host ""
}

# Test 3: Validate binary exists
Write-Host "[TEST 3] Verifying binary artifacts" -ForegroundColor Yellow
$BinaryPath = "$FirmwareDir\.pio\build\esp32-s3-devkitc-1\firmware.bin"
if (Test-Path $BinaryPath) {
    $BinarySize = (Get-Item $BinaryPath).Length
    Write-Host "✓ Binary artifact: $BinarySize bytes" -ForegroundColor Green
} else {
    Write-Host "✗ Binary artifact not found at $BinaryPath" -ForegroundColor Red
    exit 1
}
Write-Host ""

# Test 4: Check platformio.ini for required libraries
Write-Host "[TEST 4] Checking library dependencies" -ForegroundColor Yellow
$PlatformioIni = Get-Content "$FirmwareDir\platformio.ini" -Raw
if ($PlatformioIni -match "ESPAsyncWebServer") {
    Write-Host "✓ ESPAsyncWebServer library declared" -ForegroundColor Green
} else {
    Write-Host "✗ ESPAsyncWebServer not in platformio.ini" -ForegroundColor Red
    exit 1
}
if ($PlatformioIni -match "ArduinoJson") {
    Write-Host "✓ ArduinoJson library declared" -ForegroundColor Green
} else {
    Write-Host "✗ ArduinoJson not in platformio.ini" -ForegroundColor Red
    exit 1
}
Write-Host ""

Write-Host "===========================================" -ForegroundColor Green
Write-Host "All smoke tests passed! ✓" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next: Deploy to ESP32 and run hardware integration tests"
Write-Host "  curl http://192.168.1.11/healthz"
Write-Host "  curl http://192.168.1.11/api/v1/version"
