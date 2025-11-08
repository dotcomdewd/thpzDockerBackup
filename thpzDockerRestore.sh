#!/bin/bash
# thpzDockerRestore.sh – fixed & bullet-proof
# Works with sudo, finds the right home, no syntax errors

set -euo pipefail
IFS=$'\n\t'

# ================= CONFIG =================
DEFAULT_BACKUP_ROOT="$HOME/docker-backups"
BACKUP_DIR=""

# ================= HELPERS =================
require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "[-] Please run with sudo"
    exit 1
  fi
}

fix_sudo_home() {
  if [[ -n "${SUDO_USER:-}" ]] && [[ "$HOME" = /root* ]]; then
    export HOME="/home/$SUDO_USER"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "[+] Docker already installed"
    return 0
  fi

  echo "[*] Installing Docker Engine + Compose plugin..."
  apt update -qq
  apt install -y ca-certificates curl gnupg lsb-release

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable
EOF

  apt update -qq
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker.service docker.socket containerd.service >/dev/null 2>&1
  echo "[+] Docker installed"
}

pick_backup_dir() {
  local arg="${1:-}"
  local root="${DEFAULT_BACKUP_ROOT}"

  # fix path when using sudo
  [[ -n "${SUDO_USER:-}" ]] && root="/home/$SUDO_USER/docker-backups"

  if [[ -n "$arg" ]]; then
    if [[ -d "$arg" ]]; then
      BACKUP_DIR="$arg"
      return
    fi
    local candidate="$root/$arg"
    if [[ -d "$candidate" ]]; then
      BACKUP_DIR="$candidate"
      return
    fi
    echo "[-] Not found: $arg"
    exit 1
  fi

  # auto-pick newest
  if [[ ! -d "$root" ]]; then
    echo "[-] $root does not exist"
    exit 1
  fi

  BACKUP_DIR=$(ls -d "$root"/*/ 2>/dev/null | sort -r | head -n1 | cut -f1)
  BACKUP_DIR="${BACKUP_DIR%/}"   # remove trailing slash

  if [[ -z "$BACKUP_DIR" ]]; then
    echo "[-] No backup folders found in $root"
    exit 1
  fi
}

load_images() {
  shopt -s nullglob
  local files=("$BACKUP_DIR"/*_image.tar)
  shopt -u nullglob

  (( ${#files[@]} == 0 )) && { echo "[!] No image tarballs found"; return 0; }

  echo "[*] Loading ${#files[@]} image(s)"
  for f in "${files[@]}"; do
    echo "→ $(basename "$f")"
    docker load --input "$f" | sed 's/^/    /'
  done
}

restore_volumes() {
  shopt -s nullglob
  local files=("$BACKUP_DIR"/volume_*.tar.gz)
  shopt -u nullglob

  (( ${#files[@]} == 0 )) && { echo "[!] No volume archives found"; return 0; }

  echo "[*] Restoring ${#files[@]} volume(s)"
  for archive in "${files[@]}"; do
    local name="$(basename "$archive")"
    local vol="${name#volume_}"
    vol="${vol%.tar.gz}"

    echo "→ Volume: $vol"

    docker volume inspect "$vol" &>/dev/null || docker volume create "$vol" >/dev/null

    docker run --rm \
      -v "$vol:/data" \
      -v "$BACKUP_DIR:/backup:ro" \
      alpine \
      sh -c "apk add --no-cache tar && tar xzf \"/backup/$name\" -C /data --strip-components=1"
  done
}

show_env_files() {
  shopt -s nullglob
  local files=("$BACKUP_DIR"/*.env)
  shopt -u nullglob

  (( ${#files[@]} == 0 )) && return 0

  echo "[*] Found .env files:"
  printf '   %s\n' "${files[@]##*/}"
  echo
  echo "Example:"
  echo "docker run -d --name ollama \\"
  echo "  --env-file \"$BACKUP_DIR/ollama.env\" \\"
  echo "  -v local-llm_ollama:/root/.ollama -p 11434:11434 ollama/ollama"
}

# ================= MAIN =================
main() {
  echo "=== Docker Restore – Fixed Version ==="
  echo

  require_root
  fix_sudo_home
  install_docker
  pick_backup_dir "${1:-}"

  echo "[+] Backup directory: $BACKUP_DIR"
  echo

  load_images
  echo
  restore_volumes
  echo
  show_env_files

  echo "++++++++++++++++++++++++++++++++++++++++"
  echo "[+] RESTORE COMPLETE!"
  echo "++++++++++++++++++++++++++++++++++++++++"
  echo "Check with:"
  echo "  docker images"
  echo "  docker volume ls"
  echo
}

main "$@"
