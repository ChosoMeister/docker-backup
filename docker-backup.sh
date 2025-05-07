#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# docker-backup.sh
#   Dynamically backs up all Docker Compose projects under /docker,
#   including entire project folders, compose files, .env files, and named volumes.
#
# Usage:
#   sudo /usr/local/bin/docker-backup.sh
#
# Cron example (runs daily at 03:00):
#   0 3 * * * /usr/local/bin/docker-backup.sh >> /var/log/docker-backup.log 2>&1
# -----------------------------------------------------------------------------

set -euo pipefail

# Ensure Docker access
if ! docker info &>/dev/null; then
  echo "Error: Cannot communicate with Docker daemon. Run as root or in the docker group."
  exit 1
fi

# Configuration
DOCKER_ROOT="/docker"
BACKUP_ROOT="/mnt/backup"
DATE=$(date +'%F')
BACKUP_DIR="$BACKUP_ROOT/docker-backup-$DATE"

# Prepare backup dirs
mkdir -p "$BACKUP_DIR/compose" "$BACKUP_DIR/volumes" "$BACKUP_DIR/projects"
if [[ ! -w "$BACKUP_ROOT" ]]; then
  echo "Error: Cannot write to backup root $BACKUP_ROOT. Check permissions."
  exit 1
fi

# Backup each service
for dir in "$DOCKER_ROOT"/*/; do
  [ -d "$dir" ] || continue
  SERVICE=$(basename "$dir")
  echo "[BACKUP] Project: $SERVICE"

  # Locate compose file
  COMPOSE_FILE=""
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$dir$f" ]]; then
      COMPOSE_FILE="$dir$f"
      break
    fi
  done
  if [[ -z "$COMPOSE_FILE" ]]; then
    echo "  No compose file found in $SERVICE, but backing up full folder."
  fi

  # Stop containers (if compose exists)
  if [[ -n "$COMPOSE_FILE" ]]; then
    docker compose -f "$COMPOSE_FILE" --project-name "$SERVICE" stop
  fi

  # Archive entire project directory
  echo "  Archiving project folder"
  tar czf "$BACKUP_DIR/projects/${SERVICE}-project-$DATE.tar.gz" -C "$DOCKER_ROOT" "$SERVICE"

  # Save compose file (if any)
  if [[ -n "$COMPOSE_FILE" ]]; then
    cp "$COMPOSE_FILE" "$BACKUP_DIR/compose/${SERVICE}-compose-$DATE.yml"
  fi

  # Save .env if exists
  if [[ -f "${dir}.env" ]]; then
    cp "${dir}.env" "$BACKUP_DIR/compose/${SERVICE}-env-$DATE.env"
  fi

  # Backup named volumes
  if [[ -n "$COMPOSE_FILE" ]]; then
    VOLUMES=$(docker volume ls --filter label=com.docker.compose.project="$SERVICE" -q)
    for vol in $VOLUMES; do
      echo "  Archiving volume: $vol"
      docker run --rm \
        -v "$vol:/data:ro" \
        -v "$BACKUP_DIR/volumes:/backup:rw" \
        alpine sh -c "tar czf /backup/${SERVICE}_${vol}_$DATE.tar.gz -C /data ."
    done
  fi
done

# Restart all services
for dir in "$DOCKER_ROOT"/*/; do
  [ -d "$dir" ] || continue
  SERVICE=$(basename "$dir")
  # Restart if compose existed
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$dir$f" ]]; then
      echo "[START] Project: $SERVICE"
      docker compose -f "$dir$f" --project-name "$SERVICE" start
      break
    fi
  done
done

echo "Backup completed. Directory: $BACKUP_DIR"
