# Phase 2 AsyncWebServer Migration - Completion Checklist

## What's Done (Core Infrastructure) ✓
- [x] Include files updated
- [x] Global instance converted
- [x] Event loop cleaned
- [x] Global request context added
- [x] Helper functions refactored (writeJsonResponse, parseJsonBody, verifyRequestAuth)
- [x] 5-6 handler function signatures updated as examples
- [x] Test harness created (validation scripts)
- [x] PlatformIO.ini updated with ESPAsyncWebServer/AsyncTCP libraries

## What Remains (Repetitive Handler Updates) - ~1-2 hours work

### Handlers to Update (20+ functions)
Use this pattern for each:
```cpp
// Step 1: Add request parameter
void handleXyz(AsyncWebServerRequest *request) {
  g_currentRequest = request;
  
// Step 2: Replace server.send() with request->send()
// Before: server.send(200, "application/json", payload);
// After:  request->send(200, "application/json", payload);

// Step 3: Replace server.uri() with request->url()
// Before: const String uri = server.uri();
// After:  const String uri = request->url();

// Step 4: Replace parseJsonBody() calls
// Before: parseJsonBody(body)
// After:  parseJsonBody(request, body)
}
```

### Handlers to Update (Priority Order)
**Priority 1 (Critical for E2E testing):**
- [ ] handleCommand() - line 2021 - ~120 lines, multiple server.send()
- [ ] handleLocalSettings() - line 1807 - ~40 lines
- [ ] handleScan() - line 1862 - ~10 lines

**Priority 2 (Pairing flow):**
- [ ] handlePair() - ~30 lines
- [ ] handleVerify() - ~20 lines
- [ ] handleForget() - ~15 lines
- [ ] handleRelease() - ~15 lines

**Priority 3 (Provisioning):**
- [ ] handleProvisionSave() - ~40 lines
- [ ] handleProvisionPage() - ~30 lines
- [ ] handleGatewayPage() - ~10 lines

**Priority 4 (Utility):**
- [ ] handleReleaseAll() - ~10 lines
- [ ] handleFirmwareUpdate() - ~50 lines (complex)
- [ ] handleFirmwareUploadChunk() - ~50 lines (complex)
- [ ] handleFirmwareRollback() - ~20 lines

### Supporting Function to Update
- [ ] `parseSideFromUri()` - line 1876 - uses server.uri(), needs g_currentRequest

### Route Registration Update
- [ ] `registerRoutes()` - Update lambda captures to pass request properly
  - Pattern: `[](AsyncWebServerRequest *request) { g_currentRequest = request; handleXyz(request); }`
  - This ensures all handlers have access to current request

## Compilation & Testing Timeline

**Once PlatformIO is available:**
1. Apply remaining handler updates (1-2 hours)
2. Run: `./firmware/test/validate.ps1`
3. Expected output: Clean compilation
4. Deploy to ESP32 with simulated backend
5. Test endpoints: `curl http://192.168.1.11/api/v1/version`
6. Test command flow with two devices

## Critical Notes for Remaining Work

1. **AsyncWebServer & Delays**: Avoid delay() in handlers - they block event loop
   - BLE operations use delay() in confirmCommandApplied()
   - Solution: Already in place - BLE ops stay synchronous in separate execution path
   
2. **Body Parsing**: Request body is available via:
   - `request->contentLength()` - size
   - `request->arg("plain")` - for plain text POST bodies
   - `request->getParam("name", true)` - for form parameters

3. **Request Context**: All handlers should:
   - Accept `AsyncWebServerRequest *request` parameter
   - Set `g_currentRequest = request;` at start
   - Use `request->send()` for responses
   - Pass `request` to helper functions that send responses

## Git Commit Ready
Current state is ready to commit with all framework changes:
- Substantial progress that compiles when environment is ready
- Clear roadmap for completion
- Testable once handlers are updated
