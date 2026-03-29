# ESP32 Gateway

This firmware exposes the bridge-facing API contract for provisioning, claim/auth, pairing, verification, command execution, and BLE handoff.

## Current State

- Wi‑Fi station mode with soft-AP fallback
- setup AP onboarding at `http://192.168.4.1`
- mDNS advertisement as `_bedjet-bridge._tcp`
- saved Wi‑Fi SSID, password, and hostname in `Preferences`
- claim status, claim endpoint, and signed-request verification for protected routes
- persistent left/right pair slots in `Preferences`
- signed OTA firmware endpoint at `POST /api/v1/firmware/update`
- simulated backend remains available for end-to-end API testing
- real BedJet BLE backend handles on-hardware pairing, verification, and control
- built-in RGB activity light for confirmed pairing/control actions, with a web UI toggle

## Build

Install PlatformIO Core first if `pio` is not already available:

```bash
python -m pip install platformio
```

```bash
cd <repo-root>/firmware
pio run
```

## Flash

```bash
cd <repo-root>/firmware
pio run -t upload
```

Windows helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Flash-BedJetGateway.ps1 `
  -Port <com-port> `
  -WifiSsid "<wifi-ssid>" `
  -WifiPassword "<wifi-password>" `
  -GatewayHostname bedjet-gateway
```

This helper can preseed Wi-Fi for first boot by writing the gitignored local header:

- `firmware/include/wifi_secrets.h`

Example template:

- `firmware/include/wifi_secrets.example.h`

## Provisioning

If no saved Wi‑Fi credentials exist, the gateway starts a setup AP:

- SSID: `BedJetGatewaySetup`
- setup URL: `http://192.168.4.1`

From that page you can save:

- Wi‑Fi SSID
- Wi‑Fi password
- gateway hostname, default `bedjet-gateway`

After save, the gateway reboots onto your normal LAN and reports:

- station IP
- hostname
- mDNS URL, for example `http://bedjet-gateway.local`

If you want to skip the setup AP on first boot, create `firmware/include/wifi_secrets.h` from the example file or use the Windows flash helper above.

Once the gateway is already claimed and on the LAN, you can rotate Wi-Fi settings with a signed request:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Set-BedJetGatewayWifi.ps1 `
  -WifiSsid "<wifi-ssid>" `
  -WifiPassword "<wifi-password>" `
  -GatewayHostname bedjet-gateway
```

That script loads gateway URL/id/secret from `data\setup-state.json` by default.
After claim, Wi-Fi changes are meant to be deliberate and signed. First boot is the easy path; later changes are the locked door with the right key.

## Secure OTA Update

Firmware can be updated remotely (no USB) through the claimed gateway identity.

Security checks on `POST /api/v1/firmware/update`:

- gateway must already be claimed
- HMAC-signed auth headers are required (`X-Gateway-Id`, `X-Timestamp`, `X-Nonce`, `X-Signature`)
- request signature binds to firmware digest marker (`sha256:<hex>`)
- `X-Firmware-SHA256` must match the uploaded binary bytes exactly

Attestation endpoints:

- `GET /api/v1/version` returns firmware `buildId`, boot count, rollback capability, and last OTA status/SHA
- `POST /api/v1/firmware/rollback` performs signed rollback when an alternate OTA slot is available

Windows helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Update-BedJetGatewayFirmware.ps1
```

This script loads gateway URL/id/secret from `data\setup-state.json` by default, signs the upload request, and posts the compiled firmware binary from:

- `firmware\.pio\build\esp32-s3-devkitc-1\firmware.bin`

If you want the updater to trigger rollback automatically when post-update attestation fails:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Update-BedJetGatewayFirmware.ps1 `
  -RollbackOnFailedAttestation
```

Manual signed rollback helper:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Rollback-BedJetGatewayFirmware.ps1
```
