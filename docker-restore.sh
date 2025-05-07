# -----------------------------------------------------------------------------
# docker-restore.sh
#   Restores Docker Compose projects, full project folders, .env files, and volumes.
#
# Usage:
#   sudo /usr/local/bin/docker-restore.sh [backup-path] [target-root]
#
# Examples:
#   sudo docker-restore.sh                    # auto-select latest under /mnt/backup
#   sudo docker-restore.sh /mnt/backup/docker-backup-2025-05-07 /srv/docker
# -----------------------------------------------------------------------------

restore_all() {
  set -euo pipefail

  # Ensure Docker access
  if ! docker info &>/dev/null; then
    echo "Error: Cannot communicate with Docker daemon. Run as root or in the docker group."
    exit 1
  fi

  # Args
  if [[ $# -gt 2 ]]; then
    echo "Usage: $0 [backup-path] [target-root]"
    exit 1
  fi

  # Determine backup path
  if [[ $# -ge 1 && -d "$1" ]]; then
    BACKUP_PATH="$1"
  else
    BACKUP_PATH=$(ls -d /mnt/backup/docker-backup-* 2>/dev/null | sort --version-sort | tail -n1)
    [[ -n "$BACKUP_PATH" ]] || { echo "Error: No backup found."; exit 1; }
    echo "Using latest backup: $BACKUP_PATH"
  fi
  COMPOSE_DIR="$BACKUP_PATH/compose"
  PROJECTS_DIR="$BACKUP_PATH/projects"
  VOLUMES_DIR="$BACKUP_PATH/volumes"

  # Target
  TARGET_ROOT="${2:-/docker}"
  [[ -w "$(dirname "$TARGET_ROOT")" ]] || { echo "Error: Cannot write to $(dirname "$TARGET_ROOT")."; exit 1; }
  mkdir -p "$TARGET_ROOT"

  # Date suffix
  BACKUP_DATE=$(basename "$BACKUP_PATH" | sed 's/docker-backup-//')

  # Restore full project folders
  for proj_tar in "$PROJECTS_DIR"/*-project-*.tar.gz; do
    [[ -f "$proj_tar" ]] || continue
    BASENAME=$(basename "$proj_tar")
    PROJECT=${BASENAME%-project-*}
    echo "[RESTORE] Project folder: $PROJECT"
    tar xzf "$proj_tar" -C "$TARGET_ROOT"
  done

  # Restore compose/.env and volumes
  for file in "$COMPOSE_DIR"/*-compose-*.yml; do
    [ -f "$file" ] || continue
    BASE=$(basename "$file")
    PROJECT=${BASE%-compose-*}
    echo "[RESTORE] Compose & volumes: $PROJECT"

    SERVICE_DIR="$TARGET_ROOT/$PROJECT"
    # Copy compose
    cp "$file" "$SERVICE_DIR/docker-compose.yml"

    # Restore .env
    ENV_BACKUP="$COMPOSE_DIR/${PROJECT}-env-$BACKUP_DATE.env"
    if [[ -f "$ENV_BACKUP" ]]; then
      cp "$ENV_BACKUP" "$SERVICE_DIR/.env"
    fi

    # Restore volumes
    for vol_archive in "$VOLUMES_DIR/${PROJECT}_*_${BACKUP_DATE}.tar.gz"; do
      [[ -e "$vol_archive" ]] || continue
      VOL_NAME=$(basename "$vol_archive" | sed -E "s/${PROJECT}_(.*)_${BACKUP_DATE}.tar.gz/\1/")
      FULL_VOL="${PROJECT}_${VOL_NAME}"
      echo "  -> Volume: $FULL_VOL"
      docker volume inspect "$FULL_VOL" &>/dev/null || docker volume create --name "$FULL_VOL"
      docker run --rm -i -v "$FULL_VOL:/data" alpine sh -c "tar xzf - -C /data" < "$vol_archive"
    done
  done

  # Start services
  for dir in "$TARGET_ROOT"/*/; do
    [ -d "$dir" ] || continue
    PROJECT=$(basename "$dir")
    if [[ -f "$dir/docker-compose.yml" ]]; then
      echo "[UP] Starting: $PROJECT"
      (cd "$dir" && docker compose --project-name "$PROJECT" up -d)
    fi
  done

  echo "Restore completed from $BACKUP_PATH."
}

restore_all "$@"
