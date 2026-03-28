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
- simulated BedJet backend for end-to-end API testing
- real BedJet BLE backend still pending hardware validation

## Build

```bash
cd /mnt/d/Dev/bedjet-smartthings-bridge/firmware
pio run
```

## Flash

```bash
cd /mnt/d/Dev/bedjet-smartthings-bridge/firmware
pio run -t upload
```

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

You can still bake `WIFI_SSID` and `WIFI_PASSWORD` into `platformio.ini`, but the preferred path is the setup AP flow.

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
powershell -ExecutionPolicy Bypass -File D:\Dev\bedjet-smartthings-bridge\scripts\windows\Update-BedJetGatewayFirmware.ps1
```

This script loads gateway URL/id/secret from `data\setup-state.json` by default, signs the upload request, and posts the compiled firmware binary from:

- `firmware\.pio\build\esp32-s3-devkitc-1\firmware.bin`
