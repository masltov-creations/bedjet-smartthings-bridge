# SmartThings Edge Driver

Private LAN Edge driver scaffold for the BedJet bridge.

## Current Scope

- Creates four LAN devices on discovery:
  - `BedJet Left`
  - `BedJet Right`
  - `Left Nightly Bio`
  - `Right Nightly Bio`
- Talks to the bridge over local HTTP.
- Supports:
  - power on/off for left/right units
  - fan step via `switchLevel`
  - current temperature refresh
  - Nightly Bio launch/stop via switch devices

## Current Limitations

- Discovery is scaffolded, but still needs live hub validation.
- The richer BedJet mode and target-temperature UI is not yet exposed in SmartThings.
- Use the bridge UI for full control until the Edge driver is validated and expanded.

## Package Layout

- `config.yaml`
- `search-parameters.yaml`
- `profiles/`
- `src/`
