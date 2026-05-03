#!/usr/bin/env bash
# Bulk-import every JSON in workflows/ into the running n8n container.
# Usage: ./scripts/import-workflows.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if ! docker compose ps --status running n8n >/dev/null 2>&1; then
  echo "Starting n8n service..."
  docker compose up -d n8n
  echo "Waiting for n8n to be ready..."
  until curl -sf "http://localhost:${N8N_PORT:-5678}/healthz" >/dev/null 2>&1; do
    sleep 2
  done
fi

# n8n's CLI reads files from inside the container; we mount workflows/ as /workflows ro.
echo "Importing workflows from /workflows ..."
docker compose exec -T n8n n8n import:workflow --separate --input=/workflows

echo "Done. Open n8n at http://localhost:${N8N_PORT:-5678} and activate workflow 01."
