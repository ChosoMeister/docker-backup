# docker-backup

A pair of Bash scripts to back up and restore all your Docker Compose projects under a designated root directory. The backup script archives project folders, Compose files, `.env` files, and named volumes. The restore script rehydrates those archives into a target directory and starts the services.

## Table of Contents

* [Features](#features)
* [Prerequisites](#prerequisites)
* [Installation](#installation)
* [Usage](#usage)

  * [Backup](#backup)
  * [Restore](#restore)
* [Scheduling Backups](#scheduling-backups)
* [Examples](#examples)
* [License](#license)

## Features

* **Comprehensive Backup**: Archives entire project directories, Docker Compose files, `.env` files, and named volumes.
* **Dynamic Detection**: Automatically finds Docker Compose files (`docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`) in each project folder.
* **Graceful Handling**: Stops containers before backup and restarts them after.
* **Volume Preservation**: Exports and imports named volumes to ensure data continuity.
* **Restore Workflow**: Extracts archives into a target root, restores Compose and `.env` files, recreates volumes, and brings services up.

## Prerequisites

* **OS**: Linux or macOS
* **Bash**: Version 4+
* **Docker**: Docker Engine with Docker Compose plugin
* **Permissions**: Run as root or a user in the `docker` group; write access to backup and target directories.

## Installation

Clone this repository and install the scripts:

```bash
git clone https://github.com/ChosoMeister/docker-backup.git
cd docker-backup
sudo cp docker-backup.sh docker-restore.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/docker-backup.sh /usr/local/bin/docker-restore.sh
```

Optionally, create and grant permissions for the backup root:

```bash
sudo mkdir -p /mnt/backup
sudo chown $(whoami):$(whoami) /mnt/backup
```

If your Docker root or backup paths differ, edit the top of each script:

* `DOCKER_ROOT` (default: `/docker`)
* `BACKUP_ROOT` (default: `/mnt/backup`)

## Usage

### Backup

Run the backup script to archive all Docker Compose projects:

```bash
sudo /usr/local/bin/docker-backup.sh
```

No arguments are required. A timestamped directory is created under `$BACKUP_ROOT` (e.g., `/mnt/backup/docker-backup-2025-05-07`) containing:

* **`projects/`**: Archives of entire project folders
* **`compose/`**: Compose YAML files and `.env` files
* **`volumes/`**: Archives of named volumes

After completion, stopped services are restarted automatically.

### Restore

Restore from a backup into a target directory:

```bash
sudo /usr/local/bin/docker-restore.sh [backup-path] [target-root]
```

* `backup-path` (optional): Path to a specific backup folder (e.g., `/mnt/backup/docker-backup-2025-05-07`). If omitted, the latest backup is used.
* `target-root` (optional): Directory where projects will be restored (default: `/docker`).

The script will:

1. Extract project archives into the target root
2. Copy Compose and `.env` files back into each project folder
3. Recreate and populate named volumes
4. Start all Docker Compose services in detached mode

## Scheduling Backups

Add a cron job to run daily at 03:00. Edit the root crontab (`sudo crontab -e`):

```cron
0 3 * * * /usr/local/bin/docker-backup.sh >> /var/log/docker-backup.log 2>&1
```

Logs are saved to `/var/log/docker-backup.log`.

## Examples

* **Manual Backup**:

  ```bash
  sudo /usr/local/bin/docker-backup.sh
  ```
* **Manual Restore (latest)**:

  ```bash
  sudo docker-restore.sh
  ```
* **Restore Specific Backup**:

  ```bash
  sudo docker-restore.sh /mnt/backup/docker-backup-2025-04-30 /docker
  ```

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
