#!/usr/bin/env bash

set -euo pipefail

COMPOSE_DIR=${COMPOSE_DIR:-/opt/traccar}
COMPOSE_FILE=${COMPOSE_FILE:-$COMPOSE_DIR/compose.yaml}
BACKUP_DIR=${BACKUP_DIR:-$COMPOSE_DIR/backups}
APP_SERVICE=${APP_SERVICE:-traccar}
DB_SERVICE=${DB_SERVICE:-database}

cd "$COMPOSE_DIR"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "Missing compose file: $COMPOSE_FILE" >&2
  exit 1
fi

mkdir -p "$BACKUP_DIR"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
backup_file="$BACKUP_DIR/traccar-postgres-$timestamp.dump"

echo "Creating PostgreSQL backup: $backup_file"
docker compose -f "$COMPOSE_FILE" exec -T "$DB_SERVICE" \
  sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$backup_file"

if [ ! -s "$backup_file" ]; then
  echo "Backup failed or produced an empty file: $backup_file" >&2
  exit 1
fi

echo "Backup complete. Pulling and restarting only the Traccar application service."
docker compose -f "$COMPOSE_FILE" pull "$APP_SERVICE"
docker compose -f "$COMPOSE_FILE" up -d --no-deps "$APP_SERVICE"

echo "Deployment command finished. Verify health before considering the release complete."
