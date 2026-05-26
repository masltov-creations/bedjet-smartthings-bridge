# SmartThings CLI Notes

This repo targets a private SmartThings Edge LAN driver flow, not a cloud Schema app.

## CLI Availability On This Machine

- Binary: `/usr/bin/smartthings`
- Version observed: `2.0.2`

## Useful Commands

Recommended configured install flow (repo root):

Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Install-ConfiguredEdgeDriver.ps1 `
  -ChannelId <channel-id> `
  -HubId <hub-id> `
  -BridgeHost <bridge-hostname-or-ip> `
  -BridgeFallbackIp <bridge-lan-ip> `
  -BridgePort 8787
```

Linux/macOS:

```bash
./scripts/smartthings/Install-ConfiguredEdgeDriver.sh \
  --channel-id <channel-id> \
  --hub-id <hub-id> \
  --bridge-host <bridge-hostname-or-ip> \
  --bridge-fallback-ip <bridge-lan-ip>
```

Always run preference/routing validation before claiming SmartThings E2E success:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\windows\Validate-SmartThingsRouting.ps1
```

Package the driver:

```bash
XDG_STATE_HOME=/tmp smartthings edge:drivers:package <repo-root>/smartthings-edge
```

Create a channel:

```bash
XDG_STATE_HOME=/tmp smartthings edge:channels:create
```

Assign a driver to a channel:

```bash
XDG_STATE_HOME=/tmp smartthings edge:channels:assign
```

Enroll a hub in a channel:

```bash
XDG_STATE_HOME=/tmp smartthings edge:channels:enroll
```

Install a driver onto a hub:

```bash
XDG_STATE_HOME=/tmp smartthings edge:drivers:install
```

Create a custom capability later from a YAML file placed under `smartthings-edge/capabilities/` if the standard first-pass driver surface proves too limiting:

```bash
XDG_STATE_HOME=/tmp smartthings capabilities:create -i <repo-root>/smartthings-edge/capabilities/<your-capability>.yaml
```

## Notes

- The current sandbox session can read CLI help, but authenticated mutations still need a normal writable/login-capable terminal context.
- `XDG_STATE_HOME=/tmp` avoids read-only state-path issues in restricted sessions.
