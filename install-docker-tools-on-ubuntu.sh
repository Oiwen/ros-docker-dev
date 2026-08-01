#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Install Docker Engine, Docker Compose and optional NVIDIA container support.

Usage:
  ./install-docker-tools-on-ubuntu.sh [--docker-source auto|official|tuna]
                                      [--gpu auto|on|off] [--test]

Options:
  --docker-source auto      Try Docker's official repository, then TUNA mirror
                            (default).
  --docker-source official  Use Docker's official apt repository.
  --docker-source tuna      Use the TUNA Docker CE mirror.
  --gpu auto  Install NVIDIA Container Toolkit when NVIDIA hardware or the
              NVIDIA driver is detected (default).
  --gpu on    Always install and configure NVIDIA Container Toolkit.
  --gpu off   Do not install NVIDIA Container Toolkit.
  --test      Pull test images and verify Docker/GPU access after installation.
  -h, --help  Show this help.

The NVIDIA display driver must already work on the host. This script installs
the container runtime integration; it does not install or replace GPU drivers.
EOF
}

GPU_MODE="auto"
RUN_TESTS=false
DOCKER_SOURCE="auto"

while (($#)); do
  case "$1" in
    --docker-source)
      [[ $# -ge 2 ]] || { echo "--docker-source requires auto, official or tuna" >&2; exit 2; }
      DOCKER_SOURCE="$2"
      shift 2
      ;;
    --gpu)
      [[ $# -ge 2 ]] || { echo "--gpu requires auto, on or off" >&2; exit 2; }
      GPU_MODE="$2"
      shift 2
      ;;
    --test)
      RUN_TESTS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$GPU_MODE" in
  auto|on|off) ;;
  *) echo "Invalid GPU mode: $GPU_MODE (expected auto, on or off)" >&2; exit 2 ;;
esac
case "$DOCKER_SOURCE" in
  auto|official|tuna) ;;
  *) echo "Invalid Docker source: $DOCKER_SOURCE (expected auto, official or tuna)" >&2; exit 2 ;;
esac

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify this operating system." >&2
  exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This installer supports Ubuntu only (detected: ${ID:-unknown})." >&2
  exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required." >&2
  exit 1
fi

APT_OPTIONS=(-o Acquire::Retries=3)
APT_HTTP_PROXY="${http_proxy:-${HTTP_PROXY:-}}"
APT_HTTPS_PROXY="${https_proxy:-${HTTPS_PROXY:-}}"
if [[ -n "$APT_HTTP_PROXY" ]]; then
  APT_OPTIONS+=(-o "Acquire::http::Proxy=$APT_HTTP_PROXY")
fi
if [[ -n "$APT_HTTPS_PROXY" ]]; then
  APT_OPTIONS+=(-o "Acquire::https::Proxy=$APT_HTTPS_PROXY")
fi

run_apt() {
  sudo apt-get "${APT_OPTIONS[@]}" "$@"
}

install_docker() {
  echo "==> Installing Docker Engine and the Docker Compose plugin"

  if [[ -n "$APT_HTTP_PROXY" || -n "$APT_HTTPS_PROXY" ]]; then
    echo "==> Using the current shell proxy for apt"
  fi
  run_apt update
  run_apt install -y ca-certificates curl gnupg

  # Remove only conflicting distribution packages. Existing Docker CE data is
  # not deleted, so this is safe to re-run for upgrades.
  local conflicting=()
  local package
  for package in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null | grep -q '^ii'; then
      conflicting+=("$package")
    fi
  done
  if ((${#conflicting[@]})); then
    run_apt remove -y "${conflicting[@]}"
  fi

  sudo install -m 0755 -d /etc/apt/keyrings

  local official_base="https://download.docker.com/linux/ubuntu"
  local tuna_base="https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu"
  local docker_key_fingerprint="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
  local docker_base=""
  local key_file gpg_home
  key_file="$(mktemp /tmp/docker-gpg.XXXXXX)"
  gpg_home="$(mktemp -d /tmp/docker-gpg-home.XXXXXX)"
  chmod 0700 "$gpg_home"

  valid_docker_key() {
    local candidate="$1"
    GNUPGHOME="$gpg_home" gpg --batch --show-keys --with-colons "$candidate" 2>/dev/null | \
      awk -F: -v expected="$docker_key_fingerprint" \
        '$1 == "fpr" && $10 == expected { found=1 } END { exit !found }'
  }

  download_docker_key() {
    local repository_base="$1"
    : >"$key_file"
    curl --fail --silent --show-error --location \
      --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
      "$repository_base/gpg" -o "$key_file" && valid_docker_key "$key_file"
  }

  case "$DOCKER_SOURCE" in
    official)
      docker_base="$official_base"
      download_docker_key "$docker_base" || true
      ;;
    tuna)
      docker_base="$tuna_base"
      download_docker_key "$docker_base" || true
      ;;
    auto)
      echo "==> Trying Docker's official repository"
      if download_docker_key "$official_base"; then
        docker_base="$official_base"
      else
        echo "==> Official repository is unreachable; trying the TUNA mirror"
        if download_docker_key "$tuna_base"; then
          docker_base="$tuna_base"
        fi
      fi
      ;;
  esac

  if [[ -s "$key_file" ]]; then
    sudo install -m 0644 "$key_file" /etc/apt/keyrings/docker.asc
  elif [[ -s /etc/apt/keyrings/docker.asc ]] && valid_docker_key /etc/apt/keyrings/docker.asc; then
    echo "==> Key download failed; reusing the existing Docker signing key"
    [[ -n "$docker_base" ]] || docker_base="$official_base"
  else
    rm -f "$key_file"
    rm -rf "$gpg_home"
    echo "Unable to download the Docker signing key from the selected repositories." >&2
    echo "Check the local proxy, or retry with --docker-source tuna." >&2
    exit 1
  fi
  rm -f "$key_file"
  rm -rf "$gpg_home"

  if [[ -z "$docker_base" ]]; then
    docker_base="$official_base"
  fi
  echo "==> Docker apt repository: $docker_base"

  # Disable the legacy one-line source created by older versions of this
  # project; keeping both formats can cause conflicting Signed-By errors.
  if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    sudo mv /etc/apt/sources.list.d/docker.list \
      /etc/apt/sources.list.d/docker.list.disabled-by-ros-docker-dev
  fi

  local ubuntu_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  if [[ -z "$ubuntu_codename" ]]; then
    echo "Cannot determine the Ubuntu codename." >&2
    exit 1
  fi

  local docker_sources
  docker_sources=$(cat <<EOF
Types: deb
URIs: ${docker_base}
Suites: ${ubuntu_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
)
  printf '%s\n' "$docker_sources" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null

  run_apt update
  run_apt install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
  sudo systemctl enable --now docker

  local invoking_user="${SUDO_USER:-$(id -un)}"
  if [[ "$invoking_user" != "root" ]]; then
    sudo usermod -aG docker "$invoking_user"
  fi
}

has_nvidia_hardware() {
  command -v nvidia-smi >/dev/null 2>&1 || \
    [[ -e /proc/driver/nvidia/version ]] || \
    { command -v lspci >/dev/null 2>&1 && lspci -d '10de:' | grep -qi nvidia; }
}

install_nvidia_container_toolkit() {
  echo "==> Installing NVIDIA Container Toolkit"
  curl --fail --silent --show-error --location \
    --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
    https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl --fail --silent --show-error --location \
    --retry 4 --retry-all-errors --connect-timeout 10 --max-time 60 \
    https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

  run_apt update
  run_apt install -y nvidia-container-toolkit
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
}

install_docker

ENABLE_GPU=false
case "$GPU_MODE" in
  on) ENABLE_GPU=true ;;
  auto) has_nvidia_hardware && ENABLE_GPU=true ;;
  off) ;;
esac

if "$ENABLE_GPU"; then
  install_nvidia_container_toolkit
else
  echo "==> NVIDIA container support not requested or no NVIDIA GPU detected"
fi

echo "==> Installed versions"
sudo docker --version
sudo docker compose version

if "$RUN_TESTS"; then
  echo "==> Testing Docker"
  sudo docker run --rm hello-world
  if "$ENABLE_GPU"; then
    if ! nvidia-smi >/dev/null 2>&1; then
      echo "Host nvidia-smi is not working; fix/reboot the host driver before testing GPU containers." >&2
      exit 1
    fi
    echo "==> Testing GPU access from a container"
    sudo docker run --rm --runtime=nvidia --gpus all ubuntu nvidia-smi
  fi
fi

echo
echo "Installation complete."
if [[ "${SUDO_USER:-$(id -un)}" != "root" ]]; then
  echo "Log out and back in (or run 'newgrp docker') before using Docker without sudo."
fi
if "$ENABLE_GPU" && ! nvidia-smi >/dev/null 2>&1; then
  echo "Warning: NVIDIA Container Toolkit is configured, but the host driver is not currently usable."
fi
