# Troubleshooting

## Bridge Starts But No Hardware Is Connected

If `SIMULATE_FIRMWARE=true`, the bridge uses a built-in simulator. This is intentional for development before the BedJets arrive.

## Setup Or Deploy Fails Mid-Step

- Re-run the exact failing command directly from terminal.
- Capture stdout/stderr for that command.
- Verify SSH access to the bridge host with batch mode.
- Verify Docker is usable by the remote user.
- Retry only the failed step instead of redoing the full setup.

## Bridge Cannot Reach The ESP32

- Confirm the ESP32 and Ubuntu VM are on the same LAN.
- Check `FIRMWARE_API_BASE_URL`.
- Open `http://<esp32-host>/healthz` directly from a browser or curl.

## SmartThings Devices Do Nothing

- Confirm the Edge driver is installed on the correct hub.
- Confirm the device preferences point at the bridge host and port.
- Confirm the bridge can issue commands successfully from its own UI first.

## E2E Test Looks Green But Real Control Fails

If your "E2E" check only validates health endpoints or sends no-op commands, it can look green while real control is still broken.

Use a real ON path and OFF path on both sides, and verify every observable hop:

1. Trigger `ON` from SmartThings.
2. Confirm bridge recent commands show the correct side and `power=on`.
3. Confirm `POST /v1/bedjets/<side>/verify` reports `power=on`.
4. Confirm the physical BedJet is on.
5. Confirm SmartThings refresh shows `ON`.
6. Trigger `OFF` from SmartThings.
7. Confirm bridge recent commands show the correct side and `power=off`.
8. Confirm `POST /v1/bedjets/<side>/verify` reports `power=off`.
9. Confirm the physical BedJet is off.
10. Confirm SmartThings refresh shows `OFF`.

If any one of those observations fails, the system is not proven end to end.

## Vendor App Cannot Connect

Use `Release BLE` from the bridge UI before opening the official BedJet app.
