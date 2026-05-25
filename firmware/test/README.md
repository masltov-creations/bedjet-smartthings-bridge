# Firmware Integration Testing

## Test Strategy

This directory contains integration tests for the BedJet gateway firmware.

### Test Types

1. **Compilation Tests**: Verify firmware compiles without errors after each phase
   - Command: `platformio run -e esp32-s3-devkitc-1`
   - Validates: No syntax errors, code structure

2. **Simulated Backend Tests**: Run firmware with BLE simulated (BEDJET_SIMULATED_BACKEND=1)
   - Validates: HTTP endpoints, handler signatures, request/response contracts
   - Can be deployed to ESP32 or emulator

3. **Hardware Integration Tests**: Deploy to ESP32 and test with actual BLE devices
   - Validates: Real BLE operations, timing, concurrent requests
   - Run manual test sequences via curl/SmartThings app

### Running Tests

#### Compile Test (Phase Entry)
```bash
cd firmware
platformio run -e esp32-s3-devkitc-1
```

#### Simulated Backend Deployment
```bash
# Build with simulated backend enabled (default in platformio.ini)
platformio run -e esp32-s3-devkitc-1 --target upload
```

#### Test Endpoints After Deployment
```bash
# Health check
curl http://192.168.1.11/healthz

# Get version
curl http://192.168.1.11/api/v1/version

# Get state
curl http://192.168.1.11/api/v1/state

# Send command (requires paired device)
curl -X POST http://192.168.1.11/api/v1/command/left \
  -H "Content-Type: application/json" \
  -d '{"power":"on","mode":"cool"}'
```

### Phase-Specific Tests

#### Phase 2: AsyncWebServer Migration
- [x] Compilation without errors
- [ ] All HTTP endpoints respond (GET /api/v1/version, etc.)
- [ ] POST requests with JSON body work (command, claim, settings)
- [ ] Multiple concurrent requests don't block each other
- [ ] Chunked firmware upload completes successfully
- [ ] Response times improve vs. blocking WebServer

#### Phase 1: Per-Side BLE State Tracking
- [ ] Duplicate BLE reads within 200ms window are skipped
- [ ] Last read timestamp per side is tracked
- [ ] State changes are still captured after dedupe window

#### Phase 3: Driver Adaptivity
- [ ] Expedited polls (100ms, 500ms) fire after commands
- [ ] Adaptive backoff tightens poll to 1-2s on state mismatch
- [ ] Poll interval relaxes back to 5s when stable
- [ ] Two-device command latency < 3s (SmartThings app response)

### Test Harness Validation

Check `test_validation.sh` for automated smoke tests.
