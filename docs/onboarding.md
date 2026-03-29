# Onboarding

## End-to-End Setup

1. Choose a control machine (Windows/Linux/macOS) that can reach both the gateway and bridge host.
2. Flash the ESP32 gateway if it is not already running the gateway firmware.
3. If the gateway is not on Wi‑Fi yet, join the temporary SSID `BedJetGatewaySetup` and open `http://192.168.4.1`.
4. Save your Wi‑Fi SSID, password, and preferred hostname, then let the gateway reboot onto your home LAN.
5. Confirm the gateway responds on `http://bedjet-gateway.local/healthz` or at the assigned LAN IP.
6. Install/verify the bridge (PowerShell script on Windows, or manual SSH/SCP flow on Linux/macOS).
7. Pair the left BedJet while the right unit is powered off.
8. Pair the right BedJet while the left unit is powered off.
9. Verify both pairings.
10. Install the SmartThings Edge driver and point it at the bridge LAN URL.
11. Pin the devices or Nightly Bio launchers in the SmartThings app favorites.

## Why Pair One Side At A Time

Powering on only one BedJet at a time during initial pairing reduces the chance of saving the wrong BLE identity to the wrong logical side.

## Re-Pairing

Use `Forget` on the affected side, then repeat the one-side-at-a-time scan and pair flow.

## Vendor App Handoff

Use `Release BLE` before attempting to connect with the official BedJet app. Once you are done with the official app, reconnect from the bridge using `Verify`.
