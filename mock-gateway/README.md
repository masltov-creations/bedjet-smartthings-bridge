# Mock Gateway

Small Node service that mirrors the ESP32 gateway protocol closely enough to dry-run:

- gateway provisioning status
- gateway claim
- signed bridge requests
- scan, pair, verify, forget, release, and command routes

## Local Run

```bash
cd <repo-root>/mock-gateway
node src/server.mjs
```

Default URL:

- `http://127.0.0.1:8789`

## Docker Run

```bash
cd <repo-root>/mock-gateway
docker build -t bedjet-mock-gateway .
docker run --rm -p 8789:8789 bedjet-mock-gateway
```

## Dry-Run Use

Point the Windows setup script at the mock URL:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Setup-BedJetBridge.ps1 -GatewayBaseUrl http://127.0.0.1:8789
```

For a full bridge integration dry run, the mock gateway needs to be reachable from both:

- your Windows machine
- the bridge host VM

So for a realistic remote dry run, run the mock on the same VM or another host that both sides can reach.
