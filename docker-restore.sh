#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# docker-restore.sh
#   Restores Docker Compose projects, full project folders, .env files, and volumes
#   from a specified backup archive or the latest one found.
#
# Usage:
#   sudo /usr/local/bin/docker-restore.sh [path_to_backup_directory] [target_docker_root]
#
# Examples:
#   sudo docker-restore.sh                    # Auto-selects latest backup under /mnt/backup, restores to /docker
#   sudo docker-restore.sh /mnt/backup/docker-backup-2025-05-07_10-30-00
#   sudo docker-restore.sh /mnt/backup/docker-backup-2025-05-07_10-30-00 /srv/docker
# -----------------------------------------------------------------------------

# Main function wrapped to ensure all code runs within `set -euo pipefail`
restore_all() {
  set -euo pipefail

  # --- Configuration (Defaults) ---
  DEFAULT_BACKUP_PARENT_DIR="/mnt/backup" # Parent directory where backups are stored
  DEFAULT_TARGET_ROOT="/docker"           # Default Docker projects root to restore to
  # --- End Configuration ---

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
  # --- End Helper Functions ---

  log_info "Starting Docker restore process..."

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

  # --- Argument Parsing ---
  BACKUP_PATH_ARG="${1:-}"
  TARGET_ROOT_ARG="${2:-}"

  # Determine backup path
  local backup_to_restore_path
  if [[ -n "$BACKUP_PATH_ARG" && -d "$BACKUP_PATH_ARG" ]]; then
    backup_to_restore_path="$BACKUP_PATH_ARG"
    log_info "Using specified backup path: $backup_to_restore_path"
  elif [[ -n "$BACKUP_PATH_ARG" ]]; then
    log_error "Specified backup path '$BACKUP_PATH_ARG' is not a valid directory."
    exit 1
  else
    log_info "No backup path specified. Searching for the latest backup in $DEFAULT_BACKUP_PARENT_DIR..."
    # Uses version sort which handles dates/timestamps correctly if formatted consistently
    backup_to_restore_path=$(ls -d "$DEFAULT_BACKUP_PARENT_DIR"/docker-backup-*/ 2>/dev/null | sort --version-sort | tail -n1)
    if [[ -z "$backup_to_restore_path" || ! -d "$backup_to_restore_path" ]]; then
      log_error "No backups found in $DEFAULT_BACKUP_PARENT_DIR or could not determine the latest."
      exit 1
    fi
    log_info "Using latest backup found: $backup_to_restore_path"
  fi

  local compose_backup_dir="$backup_to_restore_path/compose"
  local projects_backup_dir="$backup_to_restore_path/projects"
  local volumes_backup_dir="$backup_to_restore_path/volumes"

  if [[ ! -d "$compose_backup_dir" || ! -d "$projects_backup_dir" || ! -d "$volumes_backup_dir" ]]; then
    log_error "Backup path $backup_to_restore_path does not appear to be a valid backup structure (missing compose, projects, or volumes subdirectories)."
    exit 1
  fi

  # Determine target root directory
  local target_root="$DEFAULT_TARGET_ROOT"
  if [[ -n "$TARGET_ROOT_ARG" ]]; then
    target_root="$TARGET_ROOT_ARG"
  fi
  log_info "Target Docker projects root for restore: $target_root"

  # Check write permissions for the parent of the target root
  local target_root_parent
  target_root_parent=$(dirname "$target_root")
  if [[ ! -d "$target_root_parent" ]]; then
      log_info "Parent directory of target root ($target_root_parent) does not exist. Attempting to create."
      if ! mkdir -p "$target_root_parent"; then
        log_error "Failed to create parent directory $target_root_parent. Check permissions."
        exit 1
      fi
  fi
  if [[ ! -w "$target_root_parent" ]]; then
    log_error "Cannot write to the parent of the target root ($target_root_parent). Check permissions."
    exit 1
  fi
  mkdir -p "$target_root" # Ensure target root itself exists

  # Confirmation Prompt
  read -r -p "WARNING: This will restore projects to '$target_root' from '$backup_to_restore_path'. Existing projects with the same names may be overwritten. Are you sure you want to continue? (yes/N): " confirmation
  if [[ "${confirmation,,}" != "yes" ]]; then
    log_info "Restore cancelled by user."
    exit 0
  fi

  # --- Restore Project Folders ---
  log_info "--- Restoring Project Folders ---"
  for project_tar_file in "$projects_backup_dir"/*-project.tar.gz; do
    if [[ ! -f "$project_tar_file" ]]; then
      log_info "No project archives found or pattern matched nothing. Skipping project folder restore."
      break # Exit loop if pattern matches nothing
    fi
    
    local project_archive_basename
    project_archive_basename=$(basename "$project_tar_file")
    # Extract project name: "myproject-project.tar.gz" -> "myproject"
    local project_name
    project_name=${project_archive_basename%-project.tar.gz}

    log_info "[RESTORE-PROJECT] $project_name to $target_root/$project_name"
    # Stop existing project if running, before extracting, to avoid file conflicts
    local existing_project_compose_file="$target_root/$project_name/docker-compose.yml" # Assume this name post-restore
    if [[ -f "$existing_project_compose_file" ]]; then
        log_info "  Stopping existing project '$project_name' if it's running before overwriting..."
        # Use --project-directory to ensure it targets the correct one if multiple projects have same name
        docker compose --project-directory "$target_root/$project_name" --project-name "$project_name" down --remove-orphans || log_warn "  Could not stop/remove existing project $project_name. It might not be running or an error occurred."
    fi

    if ! tar xzf "$project_tar_file" -C "$target_root"; then
      log_error "  Failed to extract project $project_name from $project_tar_file."
      # Decide if you want to continue or exit
      continue
    fi
  done

  # --- Restore Compose Files, .env Files, and Volumes ---
  log_info "--- Restoring Compose Files, .env, and Volumes ---"
  # Iterate based on compose files as they are central to a Docker Compose project
  for backed_up_compose_file in "$compose_backup_dir"/*; do
    if [[ ! -f "$backed_up_compose_file" ]]; then
      log_info "No compose file backups found in $compose_backup_dir or pattern matched nothing."
      break
    fi

    local compose_file_basename
    compose_file_basename=$(basename "$backed_up_compose_file")

    # Extract project name: "myproject-docker-compose.yml" or "myproject-env.env"
    # This regex tries to match patterns like "projectname-composefilename" or "projectname-env.env"
    local project_name
    if [[ "$compose_file_basename" =~ ^([a-zA-Z0-9_-]+)-(docker-compose\.ya?ml|compose\.ya?ml)$ ]]; then
        project_name="${BASH_REMATCH[1]}"
    elif [[ "$compose_file_basename" =~ ^([a-zA-Z0-9_-]+)-env\.env$ ]]; then
        project_name="${BASH_REMATCH[1]}"
    else
        log_warn "Could not determine project name from $compose_file_basename. Skipping."
        continue
    fi

    log_info "[RESTORE-CONFIG] Project: $project_name"
    local project_target_dir="$target_root/$project_name"
    mkdir -p "$project_target_dir" # Ensure it exists, e.g. if only .env was backed up without full project archive

    # Restore compose file (if this iteration is for a compose file)
    if [[ "$compose_file_basename" =~ ^([a-zA-Z0-9_-]+)-(docker-compose\.ya?ml|compose\.ya?ml)$ ]]; then
        cp "$backed_up_compose_file" "$project_target_dir/docker-compose.yml" # Normalize to docker-compose.yml
        log_info "  Restored compose file to $project_target_dir/docker-compose.yml"
    fi
    
    # Restore .env file
    local backed_up_env_file="$compose_backup_dir/${project_name}-env.env"
    if [[ -f "$backed_up_env_file" ]]; then
      cp "$backed_up_env_file" "$project_target_dir/.env"
      log_info "  Restored .env file to $project_target_dir/.env"
    else
      log_info "  No .env backup found for $project_name ($backed_up_env_file)."
    fi

    # Restore volumes associated with this project
    # Volume archives are named like "projectname_volumename.tar.gz"
    log_info "  Looking for volume archives for project $project_name in $volumes_backup_dir ..."
    # We need to find volumes whose names *start with* `${project_name}_`
    # The backup saves them as `vol_name.tar.gz` where `vol_name` is the full Docker volume name.
    find "$volumes_backup_dir" -maxdepth 1 -name "${project_name}_*.tar.gz" -type f -print0 | while IFS= read -r -d $'\0' vol_archive_path; do
      if [[ ! -e "$vol_archive_path" ]]; then # Should be -f, but -e is fine as find should give files
        continue
      fi
      
      local vol_archive_filename
      vol_archive_filename=$(basename "$vol_archive_path")
      # full_docker_volume_name is "projectname_actualvolume.tar.gz" -> "projectname_actualvolume"
      local full_docker_volume_name 
      full_docker_volume_name=${vol_archive_filename%.tar.gz}

      log_info "  Restoring volume: $full_docker_volume_name"
      
      # Check if volume exists, create if not
      if ! docker volume inspect "$full_docker_volume_name" &>/dev/null; then
        log_info "    Volume $full_docker_volume_name does not exist. Creating..."
        if ! docker volume create --name "$full_docker_volume_name"; then
          log_error "    Failed to create volume $full_docker_volume_name. Skipping restore for this volume."
          continue
        fi
      else
        log_info "    Volume $full_docker_volume_name already exists. Contents will be overwritten."
      fi
      
      # Restore volume contents
      # Use -i for stdin with tar, and ensure alpine/git or similar small image with tar is available
      if ! docker run --rm -i \
          -v "$full_docker_volume_name:/data:rw" \
          -v "$vol_archive_path:/backup/${vol_archive_filename}:ro" \
          alpine/git \
          sh -c "tar xzf /backup/\"${vol_archive_filename}\" -C /data"; then
        log_error "    Failed to restore data into volume $full_docker_volume_name from $vol_archive_path."
      else
        log_info "    Successfully restored volume $full_docker_volume_name."
      fi
    done
  done


  # --- Start Restored Services ---
  log_info "--- Starting Restored Services ---"
  for project_dir_path in "$target_root"/*/; do
    if [[ ! -d "$project_dir_path" ]]; then
      continue
    fi
    
    local project_name
    project_name=$(basename "$project_dir_path")
    local compose_file_to_start="$project_dir_path/docker-compose.yml" # Standardized name

    if [[ -f "$compose_file_to_start" ]]; then
      log_info "[UP] Attempting to start project: $project_name from $project_dir_path"
      # Using --project-directory to be explicit, though cd also works
      if ! docker compose --project-directory "$project_dir_path" --project-name "$project_name" up -d --remove-orphans; then
        log_warn "  Failed to start project $project_name. Check logs in $project_dir_path and docker logs for containers."
      else
        log_info "  Successfully started project $project_name."
      fi
    else
      log_info "  No docker-compose.yml found in $project_dir_path for project $project_name. Skipping auto-start."
    fi
  done

  log_info "Restore completed from $backup_to_restore_path to $target_root."
}

# Call the main function with all script arguments
restore_all "$@"
