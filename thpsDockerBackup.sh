#!/bin/bash
# dockerBackup.sh - Backup Docker containers (images + filesystems + env + named volumes)
# For each container:
#   - Export container filesystem       -> <name>_fs.tar
#   - Save underlying image            -> <name>_image.tar
#   - Export env vars (.env style)     -> <name>.env
#   - Track any named volumes used
# Then:
#   - Backup each named volume         -> volume_<volume>.tar.gz

set -euo pipefail

BACKUP_ROOT="$HOME/docker-backups"
TIMESTAMP="$(date +%F_%H-%M-%S)"
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"

mkdir -p "$BACKUP_DIR"

echo "Backup directory: $BACKUP_DIR"
echo

# Array for volumes we discover
declare -a VOLUMES_TO_BACKUP

# Get all containers (by name)
containers=$(docker ps -a --format '{{.Names}}')

if [ -z "$containers" ]; then
  echo "No containers found. Exiting."
  exit 0
fi

for container in $containers; do
  echo "======================================"
  echo "Backing up container: $container"
  echo "======================================"

  # Get the image ID used by this container
  IMAGE_ID=$(docker inspect -f '{{.Image}}' "$container" || true)

  echo "Stopping container..."
  docker stop "$container"

  # 1) Backup container filesystem
  echo "Exporting container filesystem to ${container}_fs.tar ..."
  docker export "$container" -o "$BACKUP_DIR/${container}_fs.tar"

  # 2) Backup underlying image (if we can find it)
  if [ -n "$IMAGE_ID" ]; then
    echo "Saving image $IMAGE_ID to ${container}_image.tar ..."
    docker save -o "$BACKUP_DIR/${container}_image.tar" "$IMAGE_ID" || {
      echo "WARNING: Could not save image for $container (image ID: $IMAGE_ID)"
    }
  else
    echo "WARNING: Could not determine image for $container, skipping image save."
  fi

  # 3) Backup environment variables in .env format
  ENV_FILE="$BACKUP_DIR/${container}.env"
  echo "Exporting environment variables to ${container}.env ..."
  if docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" > "$ENV_FILE"; then
    echo "Environment variables saved to $ENV_FILE"
  else
    echo "WARNING: Could not export env vars for $container"
  fi

  # 4) Discover any named volumes used by this container
  echo "Inspecting mounts for named volumes..."
  while IFS=',' read -r mtype mname msource mdest; do
    # mtype: volume or bind
    # mname: volume name (blank for bind)
    # msource: host path for bind, or volume path for volume
    # mdest: path inside container
    if [[ "$mtype" == "volume" && -n "$mname" ]]; then
      echo "  - Found named volume: $mname (mounted at $mdest)"
      VOLUMES_TO_BACKUP+=("$mname")
    fi
  done < <(docker inspect -f '{{range .Mounts}}{{println .Type "," .Name "," .Source "," .Destination}}{{end}}' "$container")

  echo "Starting container again..."
  docker start "$container"

  echo "Backup of container $container complete."
  echo
done

# ---------- Backup the discovered named volumes ----------

# Deduplicate volume list
declare -A SEEN_VOLS
echo "======================================"
echo "Backing up named volumes (if any)..."
echo "======================================"

for vol in "${VOLUMES_TO_BACKUP[@]}"; do
  [[ -z "$vol" ]] && continue
  if [[ -n "${SEEN_VOLS[$vol]:-}" ]]; then
    continue
  fi
  SEEN_VOLS["$vol"]=1

  VOL_ARCHIVE="$BACKUP_DIR/volume_${vol}.tar.gz"
  echo "Backing up volume '$vol' to $VOL_ARCHIVE ..."

  # Use a temporary container to tar the volume contents
  docker run --rm \
    -v "${vol}:/data:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine sh -c "cd /data && tar czf /backup/volume_${vol}.tar.gz ."

  echo "Volume '$vol' backup complete."
  echo
done

echo "All backups completed successfully."
echo "Backups stored in: $BACKUP_DIR"
