#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$INSTALL_DIR" ]]; then
  echo "--install-dir is required" >&2
  exit 1
fi

cd "$INSTALL_DIR"

if ! command -v docker >/dev/null 2>&1; then
  if sudo -n true >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y docker.io docker-compose-plugin
    sudo systemctl enable --now docker
  else
    echo "Docker is not installed and passwordless sudo is unavailable." >&2
    exit 1
  fi
fi

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    echo "Docker is installed but not usable by the current user." >&2
    exit 1
  fi
fi

mkdir -p bridge-data
if [[ ! -f deploy/bridge/bridge.env ]]; then
  cp deploy/bridge/bridge.env.example deploy/bridge/bridge.env
fi

# bridge.env may be generated on Windows; strip CR so sourced values are valid in bash/compose.
sed -i 's/\r$//' deploy/bridge/bridge.env
if [[ -f deploy/bridge/.env ]]; then
  sed -i 's/\r$//' deploy/bridge/.env
fi

set -a
# Export bridge env so docker compose variable interpolation can use BRIDGE_BIND_ADDRESS/BRIDGE_PORT.
source deploy/bridge/bridge.env
# Allow deploy/bridge/.env to override compose interpolation defaults without changing app runtime env.
if [[ -f deploy/bridge/.env ]]; then
  source deploy/bridge/.env
fi
BRIDGE_BIND_ADDRESS="${BRIDGE_BIND_ADDRESS:-0.0.0.0}"
BRIDGE_PORT="${BRIDGE_PORT:-8787}"
set +a
export BRIDGE_BIND_ADDRESS BRIDGE_PORT

bridge_health_host="$BRIDGE_BIND_ADDRESS"
if [[ -z "$bridge_health_host" || "$bridge_health_host" == "0.0.0.0" || "$bridge_health_host" == "::" ]]; then
  bridge_health_host="127.0.0.1"
fi

"${DOCKER[@]}" compose -f deploy/bridge/docker-compose.yml up -d --build

for attempt in $(seq 1 18); do
  container_id="$("${DOCKER[@]}" compose -f deploy/bridge/docker-compose.yml ps -q bedjet-bridge 2>/dev/null || true)"
  if [[ -n "$container_id" ]]; then
    health_status="$("${DOCKER[@]}" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id" 2>/dev/null || true)"
    if [[ "$health_status" == "healthy" ]]; then
      echo "Bridge container health is healthy."
      exit 0
    fi
    if [[ "$health_status" == "unhealthy" ]]; then
      echo "Bridge container reports unhealthy (attempt $attempt/18); retrying..." >&2
    else
      echo "Bridge container health is '$health_status' (attempt $attempt/18); retrying..." >&2
    fi
  fi

  if curl -fsS "http://${bridge_health_host}:${BRIDGE_PORT}/healthz" >/dev/null 2>&1; then
    echo "Bridge HTTP health endpoint is ready."
    exit 0
  fi

  if [[ "$attempt" -lt 18 ]]; then
    sleep 2
  fi
done

echo "Bridge health check failed after 18 attempts." >&2
exit 1
