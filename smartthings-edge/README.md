# SmartThings Edge Driver

Private LAN Edge driver for the BedJet bridge with a clean SmartThings layout.

## Current Scope

- Creates four LAN devices on discovery (intentional minimal layout):
  - `Left BedJet`
  - `Right BedJet`
  - `Left BedJet Nightly Bio`
  - `Right BedJet Nightly Bio`
- Talks to the bridge over local HTTP.
- Supports optional bridge API authentication via the `Bridge Token` device preference.
- Supports:
  - power on/off for left/right units
  - fan step via `switchLevel`
  - current temperature refresh
  - Nightly Bio launch/stop via dedicated shortcut switch devices

## Current Limitations

- Discovery is scaffolded, but still needs live hub validation.
- SmartThings custom presentation polish is still limited by stock capability layouts.

## Package Layout

- `config.yaml`
- `search-parameters.yaml`
- `profiles/`
- `src/`
