#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  Install-ConfiguredEdgeDriver.sh --channel-id <channel-id> --hub-id <hub-id> [options]

Options:
  --bridge-host <host>     SmartThings bridge host (hostname or IP). If omitted, read from data/setup-state.json.
  --bridge-fallback-ip <ip> Optional LAN IPv4 fallback. If omitted, read from data/setup-state.json.
  --bridge-port <port>     SmartThings bridge port (default: 8787).
  --channel-id <id>        SmartThings Edge channel id (required).
  --hub-id <id>            SmartThings hub id (required).
  --repo-root <path>       Repo root path (default: current working directory).
  --xdg-state-home <path>  Override XDG_STATE_HOME for SmartThings CLI.
  -h, --help               Show help.

Example:
  ./scripts/smartthings/Install-ConfiguredEdgeDriver.sh \
    --channel-id <channel-id> \
    --hub-id <hub-id> \
    --bridge-host bridge-host.local \
    --bridge-fallback-ip 192.168.1.50
EOF
}

require_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Missing required command: $name" >&2
    exit 1
  fi
}

bridge_host=""
bridge_fallback_ip=""
bridge_port="8787"
channel_id=""
hub_id=""
repo_root="$(pwd)"
xdg_state_home=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bridge-host)
      bridge_host="${2:-}"
      shift 2
      ;;
    --bridge-port)
      bridge_port="${2:-}"
      shift 2
      ;;
    --bridge-fallback-ip)
      bridge_fallback_ip="${2:-}"
      shift 2
      ;;
    --channel-id)
      channel_id="${2:-}"
      shift 2
      ;;
    --hub-id)
      hub_id="${2:-}"
      shift 2
      ;;
    --repo-root)
      repo_root="${2:-}"
      shift 2
      ;;
    --xdg-state-home)
      xdg_state_home="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$channel_id" || -z "$hub_id" ]]; then
  echo "--channel-id and --hub-id are required." >&2
  usage
  exit 1
fi

require_cmd smartthings
require_cmd python3

repo_root="$(cd "$repo_root" && pwd)"
driver_dir="$repo_root/smartthings-edge"
setup_state="$repo_root/data/setup-state.json"

if [[ -z "$bridge_host" && -f "$setup_state" ]]; then
  bridge_host="$(python3 - <<'PY' "$setup_state"
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
print((data.get("smartThingsBridgeHost") or "").strip())
PY
)"
fi

if [[ -z "$bridge_fallback_ip" && -f "$setup_state" ]]; then
  bridge_fallback_ip="$(python3 - <<'PY' "$setup_state"
import json, re, sys
path = sys.argv[1]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)
value = (data.get("smartThingsBridgeFallbackIp") or "").strip()
if not value:
    value = (data.get("bridgeLanUrl") or "").strip()
    m = re.match(r"^https?://(\d+\.\d+\.\d+\.\d+)(?::\d+)?$", value)
    value = m.group(1) if m else ""
print(value)
PY
)"
fi

if [[ -z "$bridge_host" ]]; then
  echo "Bridge host not resolved. Pass --bridge-host or run setup first." >&2
  exit 1
fi

if ! [[ "$bridge_port" =~ ^[0-9]+$ ]] || (( bridge_port < 1 || bridge_port > 65535 )); then
  echo "Invalid --bridge-port value: $bridge_port" >&2
  exit 1
fi

if [[ -n "$bridge_fallback_ip" ]] && ! [[ "$bridge_fallback_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "Invalid --bridge-fallback-ip value: $bridge_fallback_ip" >&2
  exit 1
fi

tmp_root="$(mktemp -d "/tmp/bedjet-edge-configured.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

tmp_driver="$tmp_root/smartthings-edge"
cp -R "$driver_dir" "$tmp_driver"

for profile in "$tmp_driver/profiles/bedjet-unit.v1.yaml" "$tmp_driver/profiles/bedjet-nightly-bio.v1.yaml"; do
  python3 - <<'PY' "$profile" "$bridge_host" "$bridge_port" "$bridge_fallback_ip"
import re, sys
path, host, port, fallback_ip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(path, "r", encoding="utf-8").read()
text = re.sub(
    r"(?m)^(\s*default:\s*)bedjet-bridge\.local\s*$",
    lambda m: m.group(1) + host,
    text,
)
text = re.sub(
    r"(?m)^(\s*default:\s*)8787\s*$",
    lambda m: m.group(1) + port,
    text,
)
text = re.sub(
    r"(?ms)(name:\s*bridgeFallbackIp.*?default:\s*)\"\"",
    lambda m: m.group(1) + f"\"{fallback_ip}\"",
    text,
)
open(path, "w", encoding="utf-8").write(text)
PY
done

echo "Packaging configured Edge driver with bridgeHost=$bridge_host bridgeFallbackIp=${bridge_fallback_ip:-<empty>} bridgePort=$bridge_port"
if [[ -n "$xdg_state_home" ]]; then
  XDG_STATE_HOME="$xdg_state_home" smartthings edge:drivers:package "$tmp_driver" --channel "$channel_id" --hub "$hub_id"
else
  smartthings edge:drivers:package "$tmp_driver" --channel "$channel_id" --hub "$hub_id"
fi

echo "[ok] Driver installed to hub $hub_id from channel $channel_id"
