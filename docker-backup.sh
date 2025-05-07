#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# docker-backup.sh
#   Dynamically backs up all Docker Compose projects under a specified root,
#   including entire project folders, compose files, .env files, and named volumes.
#
# Usage:
#   sudo /usr/local/bin/docker-backup.sh
#
# Cron example (runs daily at 03:00):
#   0 3 * * * /usr/local/bin/docker-backup.sh >> /var/log/docker-backup.log 2>&1
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
DOCKER_PROJECTS_ROOT="/docker" # Root directory where your Docker project folders are located
BACKUP_ROOT="/mnt/backup"      # Root directory to store backups
# --- End Configuration ---

DATE=$(date +'%Y-%m-%d_%H-%M-%S') # More precise date for potentially multiple backups a day
BACKUP_DIR="$BACKUP_ROOT/docker-backup-$DATE"
COMPOSE_FILES_TO_CHECK=("docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml")

# --- Helper Functions ---
log_info() {
  echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
  echo "[WARN] $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
  echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $1" >&2
}

cleanup_and_exit() {
  log_error "An error occurred. Attempting to restart services if they were stopped..."
  # Attempt to restart all services that might have been stopped
  # This is a best-effort restart; individual project issues might prevent startup
  for project_path in "$DOCKER_PROJECTS_ROOT"/*/; do
    [ -d "$project_path" ] || continue
    project_name=$(basename "$project_path")
    current_compose_file=""
    for cf_name in "${COMPOSE_FILES_TO_CHECK[@]}"; do
      if [[ -f "$project_path$cf_name" ]]; then
        current_compose_file="$project_path$cf_name"
        break
      fi
    done
    if [[ -n "$current_compose_file" ]]; then
      log_info "Attempting to restart project: $project_name"
      if docker compose -f "$current_compose_file" --project-name "$project_name" ps -q | grep -q .; then
         # Only try to start if it seems to be down or was managed by this script
         docker compose -f "$current_compose_file" --project-name "$project_name" start || log_warn "Failed to restart $project_name, please check manually."
      fi
    fi
  done
  exit 1
}

# Trap ERR and EXIT signals to run cleanup function
trap 'cleanup_and_exit' ERR
# Note: Trapping EXIT can be tricky if you want normal exits not to trigger parts of cleanup.
# For simplicity, ERR is often sufficient for unexpected script termination.

# --- Main Script ---
log_info "Starting Docker backup process..."

# Ensure Docker access
if ! docker info &>/dev/null; then
  log_error "Cannot communicate with Docker daemon. Ensure Docker is running and you have permissions (e.g., run as root or user in 'docker' group)."
  exit 1
fi

# Check for docker compose command
if ! command -v docker compose &>/dev/null; then
    log_error "'docker compose' command not found. Please ensure you have Docker Compose V2 installed."
    exit 1
fi


# Prepare backup dirs
log_info "Preparing backup directory: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR/compose" "$BACKUP_DIR/volumes" "$BACKUP_DIR/projects"
if [[ ! -w "$BACKUP_ROOT" ]]; then
  log_error "Cannot write to backup root $BACKUP_ROOT. Check permissions."
  exit 1 # Exit before trap for this specific check
fi
if [[ ! -w "$BACKUP_DIR" ]]; then
  log_error "Cannot write to backup directory $BACKUP_DIR. Check permissions."
  exit 1 # Exit before trap for this specific check
fi


# Store list of services to restart later to avoid restarting a service multiple times
# if it's processed in a more complex (nested) structure (though not the case here).
# More importantly, to ensure we only restart what we stop.
declare -A services_to_restart # Associative array to store project_name and compose_file_path

# --- Stop services and Backup ---
log_info "--- Starting Backup Phase ---"
for project_path in "$DOCKER_PROJECTS_ROOT"/*/; do
  if [[ ! -d "$project_path" ]]; then
    log_warn "Skipping non-directory item: $project_path"
    continue
  fi

  project_name=$(basename "$project_path")
  log_info "[BACKUP] Processing project: $project_name"

  # Locate compose file
  project_compose_file=""
  for f_name in "${COMPOSE_FILES_TO_CHECK[@]}"; do
    if [[ -f "$project_path$f_name" ]]; then
      project_compose_file="$project_path$f_name"
      break
    fi
  done

  # Stop containers (if compose exists)
  if [[ -n "$project_compose_file" ]]; then
    log_info "  Stopping project: $project_name"
    if ! docker compose -f "$project_compose_file" --project-name "$project_name" stop; then
      log_warn "  Could not stop project $project_name. It might have already been stopped or encountered an issue. Continuing backup."
    else
      services_to_restart["$project_name"]="$project_compose_file"
    fi
  else
    log_warn "  No compose file found in $project_path. Will only back up the project folder."
  fi

  # Archive entire project directory
  log_info "  Archiving project folder: $project_name"
  if ! tar -czf "$BACKUP_DIR/projects/${project_name}-project.tar.gz" -C "$DOCKER_PROJECTS_ROOT" "$project_name"; then
    log_error "  Failed to archive project folder for $project_name."
    # Decide if you want to continue with other projects or exit. For now, let set -e handle it if it's critical.
    # If not critical, remove set -e or add || true
    continue # Or implement more specific error handling
  fi


  # Save compose file (if found)
  if [[ -n "$project_compose_file" ]]; then
    compose_backup_name=$(basename "$project_compose_file")
    cp "$project_compose_file" "$BACKUP_DIR/compose/${project_name}-${compose_backup_name}"
    log_info "  Copied compose file: $compose_backup_name"
  fi

  # Save .env if exists (COMMON: inside project directory)
  project_env_file="$project_path.env"
  if [[ -f "$project_env_file" ]]; then
    cp "$project_env_file" "$BACKUP_DIR/compose/${project_name}-env.env" # Standardized backup name
    log_info "  Copied .env file."
  else
    log_info "  No .env file found at $project_env_file."
  fi

  # Backup named volumes (if compose file was found to identify them)
  if [[ -n "$project_compose_file" ]]; then
    log_info "  Looking for volumes associated with project: $project_name"
    # The label is com.docker.compose.project for project-level,
    # and com.docker.compose.project.service for service-level if needed.
    # We use the project-level label which is automatically added by Docker Compose.
    volumes_to_backup=$(docker volume ls --filter label="com.docker.compose.project=$project_name" -q)
    if [[ -z "$volumes_to_backup" ]]; then
        log_info "  No labeled volumes found for project $project_name."
    fi

    for vol_name in $volumes_to_backup; do
      log_info "  Archiving volume: $vol_name"
      # Using a temporary container to tar the volume data
      # The volume name in the archive will be its full name e.g. myproject_data
      # The file name will be ${project_name}_${vol_name_actualpart}_${DATE}.tar.gz
      # but since vol_name already contains project_name, we can simplify.
      if ! docker run --rm \
        -v "$vol_name:/data:ro" \
        -v "$BACKUP_DIR/volumes:/backup:rw" \
        alpine/git \
        sh -c "tar czf /backup/\"${vol_name}.tar.gz\" -C /data ."; then
          log_warn "  Failed to archive volume $vol_name. It might be in use or an issue occurred."
          # Decide on error handling: continue or exit. For now, log and continue.
      else
          log_info "  Successfully archived volume $vol_name to ${vol_name}.tar.gz"
      fi
    done
  fi
done

# --- Restart all services that were stopped by this script ---
log_info "--- Restarting Services Phase ---"
for project_name in "${!services_to_restart[@]}"; do
  compose_file_to_restart="${services_to_restart[$project_name]}"
  if [[ -n "$compose_file_to_restart" && -f "$compose_file_to_restart" ]]; then
    log_info "[START] Restarting project: $project_name using $compose_file_to_restart"
    if ! docker compose -f "$compose_file_to_restart" --project-name "$project_name" start; then
        log_warn "  Failed to restart project $project_name. Please check its status and logs manually."
    else
        log_info "  Successfully started project $project_name."
    fi
  else
    log_warn "  Could not find compose file to restart project $project_name. Stored path: $compose_file_to_restart"
  fi
done

log_info "Backup completed. Backup data is in: $BACKUP_DIR"
trap - ERR # Remove trap if script completes successfully
exit 0
