#!/usr/bin/env bash
# Pull every model listed in OLLAMA_MODELS (.env) into the running ollama container.
# Usage: ./scripts/pull-models.sh
set -euo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
fi

: "${OLLAMA_MODELS:=mistral:7b-instruct-q4_K_M}"

if ! docker compose ps --status running ollama >/dev/null 2>&1; then
  echo "Starting ollama service..."
  docker compose up -d ollama
fi

echo "Waiting for ollama to be ready..."
until curl -sf http://localhost:11434/api/tags >/dev/null; do
  sleep 2
done

IFS=',' read -ra MODELS <<< "$OLLAMA_MODELS"
for model in "${MODELS[@]}"; do
  model="${model// /}"
  [ -z "$model" ] && continue
  echo ">>> ollama pull $model"
  docker compose exec -T ollama ollama pull "$model"
done

echo "Done. Installed models:"
docker compose exec -T ollama ollama list
