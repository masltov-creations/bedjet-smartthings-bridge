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

## Vendor App Cannot Connect

Use `Release BLE` from the bridge UI before opening the official BedJet app.
