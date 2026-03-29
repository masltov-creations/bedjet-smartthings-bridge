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

DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  else
    echo "Docker is installed but not usable by the current user." >&2
    exit 1
  fi
fi

mkdir -p bridge-data
if [[ ! -f deploy/bridge/bridge.env ]]; then
  cp deploy/bridge/bridge.env.example deploy/bridge/bridge.env
fi

$DOCKER compose -f deploy/bridge/docker-compose.yml up -d --build

for attempt in $(seq 1 12); do
  if curl -fsS http://127.0.0.1:8787/healthz; then
    exit 0
  fi

  if [[ "$attempt" -lt 12 ]]; then
    echo "Bridge health check not ready yet (attempt $attempt/12); retrying..." >&2
    sleep 2
  fi
done

echo "Bridge health check failed after 12 attempts." >&2
exit 1
