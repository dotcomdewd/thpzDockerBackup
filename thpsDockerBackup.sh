#!/bin/bash
# dockerRestore.sh - Restore Docker images and named volumes from backup.
# - Checks for Docker; installs it if missing
# - Loads all *_image.tar files from the chosen backup directory
# - Restores any volume_*.tar.gz into Docker named volumes
#
# Usage:
#   sudo ./dockerRestore.sh                  # use the most recent backup under ~/docker-backups
#   sudo ./dockerRestore.sh /path/to/dir     # use a specific backup directory
#   sudo ./dockerRestore.sh 2025-11-07_12-34-56   # subdir under ~/docker-backups

set -euo pipefail

BACKUP_DIR=""

# ---------- Functions ----------

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "[-] Please run this script with sudo or as root."
    exit 1
  fi
}

install_docker_if_missing() {
  if command -v docker &>/dev/null; then
    echo "[+] Docker is already installed."
    return
  fi

  echo "[*] Docker not found. Installing Docker Engine and Compose plugin..."

  apt update
  apt install -y ca-certificates curl gnupg lsb-release

  install -m 0755 -d /etc/apt/keyrings || true
  if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  fi

  echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker

  echo "[+] Docker installed and service started."
}

pick_backup_dir() {
  local BACKUP_ROOT="$HOME/docker-backups"
  local ARG="${1:-}"

  if [[ -n "$ARG" ]]; then
    # If user gave an absolute/relative path and it exists, use it
    if [[ -d "$ARG" ]]; then
      BACKUP_DIR="$ARG"
      return
    fi

    # Otherwise, see if it's a subdir under ~/docker-backups
    if [[ -d "$BACKUP_ROOT/$ARG" ]]; then
      BACKUP_DIR="$BACKUP_ROOT/$ARG"
      return
    fi

    echo "[-] Backup directory '$ARG' not found (nor '$BACKUP_ROOT/$ARG')."
    exit 1
  fi

  # No argument: pick most recent backup under ~/docker-backups
  if [[ ! -d "$BACKUP_ROOT" ]]; then
    echo "[-] No backup root directory found at $BACKUP_ROOT"
    exit 1
  fi

  local LATEST
  LATEST=$(ls -dt "$BACKUP_ROOT"/*/ 2>/dev/null | head -n1 || true)

  if [[ -z "$LATEST" ]]; then
    echo "[-] No backup directories found under $BACKUP_ROOT"
    exit 1
  fi

  BACKUP_DIR="${LATEST%/}"
}

load_images_from_backup() {
  shopt -s nullglob
  local IMAGE_FILES=("$BACKUP_DIR"/*_image.tar)

  if (( ${#IMAGE_FILES[@]} == 0 )); then
    echo "[!] No *_image.tar files found in $BACKUP_DIR"
    echo "    If this is only a volume backup, you can skip image restore."
    shopt -u nullglob
    return
  fi

  echo "[*] Found ${#IMAGE_FILES[@]} image backup(s) in $BACKUP_DIR"
  echo

  for img_tar in "${IMAGE_FILES[@]}"; do
    echo "======================================"
    echo "[*] Loading image from: $img_tar"
    echo "======================================"
    local OUTPUT
    OUTPUT=$(docker load -i "$img_tar")
    echo "$OUTPUT"
    echo
  done

  shopt -u nullglob
}

restore_volumes_from_backup() {
  shopt -s nullglob
  local VOL_ARCHIVES=("$BACKUP_DIR"/volume_*.tar.gz)

  if (( ${#VOL_ARCHIVES[@]} == 0 )); then
    echo "[!] No volume_*.tar.gz archives found in $BACKUP_DIR"
    shopt -u nullglob
    return
  fi

  echo "[*] Found ${#VOL_ARCHIVES[@]} volume backup(s) in $BACKUP_DIR"
  echo

  for vol_file in "${VOL_ARCHIVES[@]}"; do
    local base
    base=$(basename "$vol_file")
    # volume_<name>.tar.gz -> <name>
    local vol_name="${base#volume_}"
    vol_name="${vol_name%.tar.gz}"

    echo "======================================"
    echo "[*] Restoring volume '$vol_name' from $base"
    echo "======================================"

    # Create volume if it doesn't exist
    if ! docker volume inspect "$vol_name" &>/dev/null; then
      echo "  - Creating Docker volume '$vol_name'..."
      docker volume create "$vol_name" >/dev/null
    else
      echo "  - Docker volume '$vol_name' already exists. Contents will be overwritten."
    fi

    # Use a temporary container to untar into the volume
    docker run --rm \
      -v "${vol_name}:/data" \
      -v "${BACKUP_DIR}:/backup" \
      alpine sh -c "cd /data && tar xzf /backup/${base}"

    echo "  - Volume '$vol_name' restore complete."
    echo
  done

  shopt -u nullglob
}

print_env_files_info() {
  shopt -s nullglob
  local ENV_FILES=("$BACKUP_DIR"/*.env)

  if (( ${#ENV_FILES[@]} == 0 )); then
    echo "[!] No .env files found in $BACKUP_DIR"
    shopt -u nullglob
    return
  fi

  echo "[*] Found the following env files in $BACKUP_DIR:"
  for envf in "${ENV_FILES[@]}"; do
    echo "    - $(basename "$envf")"
  done
  echo
  echo "You can use these with docker run like:"
  echo "  docker run -d --name <container_name> --env-file $BACKUP_DIR/<container>.env -p <hostPort>:<containerPort> \\"
  echo "             -v local-llm_ollama:/root/.ollama <image:tag>"
  echo
  shopt -u nullglob
}

# ---------- Main ----------

require_root
install_docker_if_missing
pick_backup_dir "${1:-}"

echo "[+] Using backup directory: $BACKUP_DIR"
echo

load_images_from_backup
restore_volumes_from_backup
print_env_files_info

echo "[+] Restore steps complete."
echo
echo "Next steps (manual, per container), e.g. for Ollama:"
echo "  1) docker images          # find the restored ollama image name:tag"
echo "  2) docker volume ls       # confirm 'local-llm_ollama' exists"
echo "  3) Start container, for example:"
echo "       docker run -d --name ollama \\"
echo "         --env-file $BACKUP_DIR/ollama.env \\"
echo "         -v local-llm_ollama:/root/.ollama \\"
echo "         -p 11434:11434 \\"
echo "         <ollama-image:tag>"
echo
echo "Your Ollama models and data should now be present in the restored volume 'local-llm_ollama'."
