#!/bin/bash

# Firmware Integration Test Validation Script
# Runs smoke tests at each phase to catch compilation and basic contract errors

set -e  # Exit on first error

FIRMWARE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$(cd "$FIRMWARE_DIR/.." && pwd)"

echo "=========================================="
echo "Firmware Integration Test Validation"
echo "=========================================="
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test 1: Verify PlatformIO is installed
echo -e "${YELLOW}[TEST 1] Checking PlatformIO installation${NC}"
if ! command -v platformio &> /dev/null; then
    echo -e "${RED}✗ PlatformIO not found. Install with: pip install platformio${NC}"
    exit 1
fi
echo -e "${GREEN}✓ PlatformIO found: $(platformio --version)${NC}"
echo ""

# Test 2: Compile firmware (with simulated backend)
echo -e "${YELLOW}[TEST 2] Compiling firmware with simulated backend${NC}"
cd "$FIRMWARE_DIR"
if platformio run -e esp32-s3-devkitc-1 2>&1 | tee build.log; then
    echo -e "${GREEN}✓ Compilation successful${NC}"
    BUILD_SIZE=$(grep -oP 'RAM:\s*\K[^\s]+' build.log || echo "unknown")
    BUILD_TIME=$(grep -oP 'took\s+\K[^\s]+' build.log || echo "unknown")
    echo "  Build size: $BUILD_SIZE bytes, time: $BUILD_TIME seconds"
else
    echo -e "${RED}✗ Compilation failed${NC}"
    tail -50 build.log
    exit 1
fi
echo ""

# Test 3: Validate binary exists
echo -e "${YELLOW}[TEST 3] Verifying binary artifacts${NC}"
if [ -f "$FIRMWARE_DIR/.pio/build/esp32-s3-devkitc-1/firmware.bin" ]; then
    BIN_SIZE=$(stat -f%z "$FIRMWARE_DIR/.pio/build/esp32-s3-devkitc-1/firmware.bin" 2>/dev/null || stat -c%s "$FIRMWARE_DIR/.pio/build/esp32-s3-devkitc-1/firmware.bin")
    echo -e "${GREEN}✓ Binary artifact: $BIN_SIZE bytes${NC}"
else
    echo -e "${RED}✗ Binary artifact not found${NC}"
    exit 1
fi
echo ""

# Test 4: Check build warnings
echo -e "${YELLOW}[TEST 4] Checking for compilation warnings${NC}"
WARNING_COUNT=$(grep -c "warning:" build.log || echo 0)
if [ "$WARNING_COUNT" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Found $WARNING_COUNT warnings:${NC}"
    grep "warning:" build.log | head -10
else
    echo -e "${GREEN}✓ No warnings${NC}"
fi
echo ""

# Test 5: Validate JSON includes (ArduinoJson available)
echo -e "${YELLOW}[TEST 5] Checking library dependencies${NC}"
if grep -q "ESPAsyncWebServer" "$FIRMWARE_DIR/platformio.ini"; then
    echo -e "${GREEN}✓ ESPAsyncWebServer library declared${NC}"
else
    echo -e "${RED}✗ ESPAsyncWebServer not in platformio.ini${NC}"
    exit 1
fi
if grep -q "ArduinoJson" "$FIRMWARE_DIR/platformio.ini"; then
    echo -e "${GREEN}✓ ArduinoJson library declared${NC}"
else
    echo -e "${RED}✗ ArduinoJson not in platformio.ini${NC}"
    exit 1
fi
echo ""

echo -e "${GREEN}=========================================="
echo "All smoke tests passed! ✓"
echo "==========================================${NC}"
echo ""
echo "Next: Deploy to ESP32 and run hardware integration tests"
echo "  curl http://192.168.1.11/healthz"
echo "  curl http://192.168.1.11/api/v1/version"
