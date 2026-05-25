# AsyncWebServer Migration - Remaining Work

## Status
Phase 2 (AsyncWebServer) is ~60% complete. The major structural changes have been made, but several handler functions still need signature updates.

## Changes Made So Far
✓ Headers updated (WebServer.h → ESPAsyncWebServer.h)
✓ Global instance changed to AsyncWebServer
✓ loop() cleaned up (removed handleClient())
✓ Global request context added (g_currentRequest)
✓ Core helper functions updated (writeJsonResponse, parseJsonBody, verifyRequestAuth)
✓ 5-6 handler signatures updated

## Remaining Handler Updates Needed

### Option A: Quick Automated Batch (Recommended)
Create a script to batch-replace all remaining handlers. Pattern:
```cpp
// Before:
void handleXyz() {
  // ... uses server.send(), server.uri(), server.method()
}

// After:
void handleXyz(AsyncWebServerRequest *request) {
  g_currentRequest = request;
  // ... replace server.send() with request->send()
  // ... replace server.uri() with request->url()
  // ... replace server.method() with request->method()
}
```

### Option B: Critical Handlers First
Update high-priority handlers:
1. handleCommand (critical for E2E testing) - ~40 lines
2. handleLocalSettings - ~30 lines
3. handleScan - ~10 lines
4. handlePair, handleVerify, handleForget, handleRelease - ~10 lines each
5. handleReleaseAll - ~5 lines
6. Provisioning handlers (handleProvisionSave, handleProvisionPage, handleGatewayPage) - ~30 lines each

Then update `registerRoutes()` to set `g_currentRequest` before calling handlers.

### Option C: RequestHandlerAdapters (Most Robust)
Create adapter functions that wrap handlers:
```cpp
class RequestAdapter {
  static void adapt(std::function<void(AsyncWebServerRequest*)> handler) {
    return [handler](AsyncWebServerRequest *request) {
      g_currentRequest = request;
      handler(request);
    };
  }
};

// Then in registerRoutes:
server.on("/api/v1/version", HTTP_GET, RequestAdapter::adapt(handleVersion));
```

## Function Updates Still Needed
- parseSideFromUri() - uses server.uri(), needs g_currentRequest
- ~20 handler functions - need signature updates and server.* → request->* replacements
- registerRoutes() - needs to properly pass requests to all handlers
- ~5 inline lambdas in registerRoutes() - need request parameter

## Next Steps for User
1. Choose Option A/B/C above
2. If environment ready: Apply remaining changes and compile
3. Run validation suite: `firmware/test/validate.ps1`
4. Deploy to hardware and test E2E

## Compilation Timeline
- With Option A (automated): ~30 mins once script is created
- With Option B (manual critical handlers): ~1 hour to update all handlers
- With Option C (robust adapters): ~2 hours for full refactor + testing

## Risk Assessment
- **Low Risk**: Changes maintain HTTP API contract, just underlying server type changes
- **Medium Risk**: AsyncWebServer event loop handling - BLE operations need separate thread/task
- **Testing Needed**: Concurrent request handling, firmware upload with OTA, BLE command processing
