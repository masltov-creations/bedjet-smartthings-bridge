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

  if curl -fsS http://127.0.0.1:8787/healthz >/dev/null 2>&1; then
    echo "Bridge HTTP health endpoint is ready."
    exit 0
  fi

  if [[ "$attempt" -lt 18 ]]; then
    sleep 2
  fi
done

echo "Bridge health check failed after 18 attempts." >&2
exit 1
