# BedJet SmartThings Bridge Plan

## Locked Decisions

- Repo path: `/mnt/d/Dev/bedjet-smartthings-bridge`
- Setup UX: script-first path now takes priority; local web `setup-app` remains secondary until the flow is simpler
- Debug mode: explicit runtime toggle, default `on` for now
- BedJet generation: `BedJet 3`
- Control topology target: one `ESP32-S3` gateway for two BedJets, with fallback to one board per side if reliability fails
- Control plane: Dockerized bridge on Ubuntu VM
- SmartThings path: private `Hub Edge LAN` driver
- Runtime network path: LAN-first for SmartThings and gateway traffic; Tailscale is optional admin access only
- Setup host selection: discover saved/active SSH candidates, but require explicit user choice before remote work
- Profile model: separate left/right Nightly Bio profiles
- Firmware strategy: custom gateway with `ESPHome BedJet` behavior as reference
- Gateway access control: bridge claims the gateway and signs protected LAN requests

## Milestones

| Milestone | Status | Notes |
| --- | --- | --- |
| Repo scaffold | Complete | Root repo, docs, CI placeholder, bridge, firmware, and SmartThings directories created |
| Setup wizard MVP | Complete | Local setup-app, concise single-card UI, unified step loop, permissioned SSH discovery, debug-mode SSE stream, and handoff generation |
| Script-first setup path | Complete | Windows PowerShell scripts for local checks, SSH, remote LAN, gateway claim, Docker, remote deploy, and bridge health/status |
| Gateway claim/auth scaffold | Complete | Bridge config/client and firmware endpoints for claim status, claim, and signed protected requests |
| Gateway Wi‑Fi provisioning scaffold | Complete | ESP32 setup AP, provisioning page, saved Wi‑Fi config, and LAN identity reporting |
| Gateway local admin UI | Complete | ESP-hosted page for Wi‑Fi updates, scan, left/right pairing management, BLE release, and basic test commands |
| Mock gateway dry-run service | Complete | Node service for provisioning, claim, signed requests, and pairing dry runs before hardware |
| Remote deploy artifacts | Complete | Docker Compose file and remote install script checked in under `deploy/bridge` |
| Bridge service MVP | Complete | SQLite persistence, onboarding UI, REST API, simulated firmware transport, Nightly Bio engine |
| ESP32 gateway scaffold | Complete | Wi‑Fi + HTTP API + persisted pair slots + simulated BedJet backend |
| SmartThings Edge scaffold | Complete | Package structure, profiles, LAN driver skeleton, CLI packaging docs |
| Real BedJet BLE backend | Complete | BLE scan/connect/write path is implemented in firmware; needs real-hardware validation against BedJet V3 |
| SmartThings hub install + validation | In progress | Needs authenticated CLI session and hub enrollment |
| Dual-unit reliability validation | Pending | Acceptance gate for one-board vs one-board-per-side decision |

## Current Execution Status

- The bridge and Windows-first setup scripts are now the primary execution path.
- The setup wizard remains in the repo but is no longer the primary path until the simplified flow is rebuilt on top of the scripts.
- `setup-app/node --test` passes in this workspace.
- `bridge/node --test` passes in this workspace.
- The runtime topology is now explicitly LAN-first for SmartThings and bridge-to-gateway traffic.
- The bridge-to-gateway security model is now a claim + signed-request scaffold rather than open LAN HTTP.
- The main setup script now performs local gateway discovery, claim, shared-secret persistence, remote bridge deploy, and bridge-to-gateway verification in one run.
- The firmware now exposes a real first-boot provisioning path instead of requiring compile-time Wi‑Fi credentials.
- A mock gateway now exists so the script and bridge can be dry-run without the real ESP32.
- The setup wizard now uses a unified `need -> permission -> run -> verify` contract across the main flow.
- The setup wizard now supports a fake-run path for end-to-end rehearsal without external side effects.
- The setup wizard can persist session state, stream debug events over SSE, inspect saved/active SSH candidates with permission, verify SSH reachability, precheck remote Docker, generate remote handoffs, and proxy BedJet pairing actions through the bridge.
- The remote deployment artifact and install script are checked in, but real SSH deployment has not been exercised yet.
- The firmware now exposes a local ESP admin page plus local admin APIs for pairing and test control, and now uses a real BLE transport path instead of the simulator.
- PlatformIO is not installed on this machine, so firmware compilation was not run here.
- The SmartThings Edge package is scaffolded for local LAN integration and device creation, and the setup wizard now has a CLI-driven SmartThings step plus handoff fallback.

## Next Milestone

1. Reflash the ESP32 and validate the local admin page on real hardware.
2. Validate left/right pairing against real units through the ESP admin page.
3. Package and install the SmartThings driver onto your hub using the bridge LAN address.
4. Validate routines, household access, and BLE handoff.
5. Stress-test one ESP against both BedJets.

## Acceptance Checklist

- [x] Dedicated repo exists
- [x] `README.md` reflects actual implemented behavior
- [x] `PLAN.md` reflects current status and next work
- [x] Local setup wizard exists with step state and debug mode
- [x] Setup wizard exposes generic step-loop, SSH selection, mock-mode, handoff, and debug endpoints
- [x] Setup wizard saves a debug bundle
- [x] Remote deployment artifact and install script are checked in
- [x] Bridge persists pairings, profiles, and schedules
- [x] Bridge exposes onboarding and control endpoints
- [x] Bridge ships with tests
- [x] Firmware exposes the same API contract the bridge expects
- [x] Firmware exposes a local admin page for Wi‑Fi and pairing management
- [x] SmartThings Edge package and CLI docs are checked in
- [ ] Real SSH bridge install verified
- [ ] Real BedJet BLE scan/pair/command verified on physical units
- [ ] SmartThings hub installation verified
- [ ] One-ESP32-two-BedJet stress test passed
