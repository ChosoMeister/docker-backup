# Docker Backup and Restore

This repository contains two scripts to help you back up and restore all your Docker Compose projects under a designated root directory. The backup script archives entire project folders, Docker Compose files, environment files, and named volumes. The restore script rehydrates those archives into a target directory and starts the services.

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

* **Comprehensive Backup**: Captures entire project directories, Docker Compose files, `.env` files, and named volumes.
* **Dynamic Detection**: Automatically finds Docker Compose files (`docker-compose.yml`, `.yaml`, or `compose.*`) in each project folder.
* **Graceful Handling**: Stops containers before archiving and restarts them after the backup.
* **Volume Preservation**: Archives and restores named volumes to ensure data continuity.
* **Restore Workflow**: Extracts archives into a target root, restores compose files and environment variables, recreates volumes, and brings services up.

## Prerequisites

* **Operating System**: Linux or macOS (with GNU utilities).
* **Bash**: `bash` version 4+.
* **Docker**: Docker Engine with Docker Compose plugin.
* **Permissions**: Run as root or a user in the `docker` group for Docker access, and sufficient write permissions to backup and target directories.

## Installation

1. **Clone the repository**:

   ```bash
   git clone https://github.com/<your-username>/<your-repo>.git
   cd <your-repo>
   ```
2. **Copy scripts to a system-wide location**:

   ```bash
   sudo cp docker-backup.sh docker-restore.sh /usr/local/bin/
   ```
3. **Make them executable**:

   ```bash
   sudo chmod +x /usr/local/bin/docker-backup.sh /usr/local/bin/docker-restore.sh
   ```
4. **Create backup root** (if not existing):

   ```bash
   sudo mkdir -p /mnt/backup
   sudo chown $(whoami):$(whoami) /mnt/backup
   ```
5. **Adjust variables** in the scripts if your Docker root or backup paths differ:

   * `DOCKER_ROOT` (default: `/docker`)
   * `BACKUP_ROOT` (default: `/mnt/backup`)

## Usage

### Backup

Run the backup script to archive all Docker Compose projects:

```bash
sudo /usr/local/bin/docker-backup.sh
```

* **Arguments**: None.
* **Output**: Creates a timestamped folder under `$BACKUP_ROOT` (e.g., `/mnt/backup/docker-backup-2025-05-07`) containing:

  * `projects/`: `.tar.gz` archives of each project folder.
  * `compose/`: backed-up Compose YAML files and `.env` files.
  * `volumes/`: `.tar.gz` archives of named volumes.

After completion, the script restarts all previously stopped services and prints the backup directory path.

### Restore

Restore from a backup archive into a target root directory:

```bash
sudo /usr/local/bin/docker-restore.sh [backup-path] [target-root]
```

* **Arguments**:

  1. `backup-path` (optional): Path to a specific backup folder (e.g., `/mnt/backup/docker-backup-2025-05-07`).

     * If omitted, the script auto-selects the latest backup in `$BACKUP_ROOT`.
  2. `target-root` (optional): Directory where projects will be restored (default: `/docker`).

* **Process**:

  1. Extracts each project archive into the target root.
  2. Copies back Compose YAML and `.env` files to each project folder.
  3. Recreates Docker volumes and imports data.
  4. Starts all Docker Compose services in detached mode.

* **Example** (restore latest to `/srv/docker`):

  ```bash
  sudo docker-restore.sh /mnt/backup/docker-backup-2025-05-07 /srv/docker
  ```

## Scheduling Backups

To run daily backups at 03:00 via cron, add the following line to the root crontab (`sudo crontab -e`):

```cron
0 3 * * * /usr/local/bin/docker-backup.sh >> /var/log/docker-backup.log 2>&1
```

This logs the output for auditing and troubleshooting.

## Examples

1. **Manual Backup**:

   ```bash
   sudo /usr/local/bin/docker-backup.sh
   ```
2. **Manual Restore of Latest**:

   ```bash
   sudo docker-restore.sh
   ```
3. **Restore Specific Backup**:

   ```bash
   sudo docker-restore.sh /mnt/backup/docker-backup-2025-04-30 /docker
   ```

## License

This project is licensed under the [MIT License](LICENSE).
