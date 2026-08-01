#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
HOST_USER="$(id -un)"
HOST_HOME_DIR="$(getent passwd "$HOST_UID" | cut -d: -f6)"
HOST_DISPLAY="${DISPLAY:-:0}"
LAUNCHER_DIR="${ROS_DEV_BIN_DIR:-$HOST_HOME_DIR/.local/bin}"

PROJECT_NAME=""
DEFAULT_PROJECT_NAME="traj"
CATKIN_WS="$(realpath "$SCRIPT_ROOT/..")"
DEVELOP_ENVIRONMENT="local"
DEFAULT_SHELL="bash"
GPU_MODE="auto"
CUDA_VERSION="auto"
PRIVILEGED=true
BUILD_MODE="ask"

usage() {
  cat <<'EOF'
Generate a ROS Noetic development container configuration.

Usage:
  ./generate.sh [options]

Options:
  --name NAME             Environment/container name.
  --workspace PATH        Catkin workspace mounted into the container.
  --environment MODE      local or remote (default: local).
  --shell SHELL           bash or zsh (default: bash).
  --gpu MODE              auto, on or off (default: auto).
  --cuda-version VERSION  CUDA Toolkit version, e.g. 12.8 or none (default: auto).
  --privileged            Enable privileged mode (default; useful for robots).
  --no-privileged         Disable privileged mode and the /dev bind mount.
  --build                 Build the image after generation.
  --no-build              Do not build the image after generation.
  -h, --help              Show this help.

Missing values are prompted for when run in a terminal. In non-interactive use,
--name is required. Example:

  ./generate.sh --name traj --workspace /path/to/ws --gpu on --cuda-version 12.8 --build
EOF
}

need_value() {
  [[ $# -ge 2 ]] || { echo "$1 requires a value" >&2; exit 2; }
}

prompt_choice() {
  local variable_name="$1"
  local prompt_text="$2"
  local allowed_pattern="$3"
  local current_value="${!variable_name}"
  local answer

  while true; do
    read -r -p "$prompt_text [$current_value]: " answer || answer=""
    answer="${answer:-$current_value}"
    if [[ "$answer" =~ $allowed_pattern ]]; then
      printf -v "$variable_name" '%s' "$answer"
      return
    fi
    echo "输入无效，请重新选择。"
  done
}

prompt_yes_no() {
  local variable_name="$1"
  local prompt_text="$2"
  local current_value="${!variable_name}"
  local hint="y/N"
  local answer
  [[ "$current_value" == "true" ]] && hint="Y/n"

  while true; do
    read -r -p "$prompt_text [$hint]: " answer || answer=""
    case "$answer" in
      [yY]|[yY][eE][sS]) printf -v "$variable_name" '%s' true; return ;;
      [nN]|[nN][oO]) printf -v "$variable_name" '%s' false; return ;;
      "") return ;;
      *) echo "请输入 y 或 n。" ;;
    esac
  done
}

detect_cuda_version() {
  local nvcc_command=""
  local output=""
  local version=""
  local cuda_path=""

  if command -v nvcc >/dev/null 2>&1; then
    nvcc_command="$(command -v nvcc)"
  elif [[ -x /usr/local/cuda/bin/nvcc ]]; then
    nvcc_command=/usr/local/cuda/bin/nvcc
  fi

  if [[ -n "$nvcc_command" ]]; then
    output="$($nvcc_command --version 2>/dev/null || true)"
    version="$(sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' <<<"$output" | head -n 1)"
    if [[ -n "$version" ]]; then
      printf '%s\n' "$version"
      return
    fi
  fi

  for cuda_path in /usr/local/cuda /usr/local/cuda-*; do
    [[ -e "$cuda_path" ]] || continue
    version="$(basename "$(realpath "$cuda_path")" | sed -nE 's/^cuda-([0-9]+\.[0-9]+)$/\1/p')"
    if [[ -n "$version" ]]; then
      printf '%s\n' "$version"
      return
    fi
  done

  if command -v nvidia-smi >/dev/null 2>&1; then
    output="$(nvidia-smi 2>/dev/null || true)"
    version="$(sed -nE 's/.*CUDA Version: *([0-9]+\.[0-9]+).*/\1/p' <<<"$output" | head -n 1)"
    if [[ -n "$version" ]]; then
      printf '%s\n' "$version"
    fi
  fi
}

DETECTED_CUDA_VERSION="$(detect_cuda_version)"

while (($#)); do
  case "$1" in
    --name)
      need_value "$@"; PROJECT_NAME="$2"; shift 2 ;;
    --workspace)
      need_value "$@"; CATKIN_WS="$2"; shift 2 ;;
    --environment)
      need_value "$@"; DEVELOP_ENVIRONMENT="$2"; shift 2 ;;
    --shell)
      need_value "$@"; DEFAULT_SHELL="$2"; shift 2 ;;
    --gpu)
      need_value "$@"; GPU_MODE="$2"; shift 2 ;;
    --cuda-version)
      need_value "$@"; CUDA_VERSION="$2"; shift 2 ;;
    --privileged)
      PRIVILEGED=true; shift ;;
    --no-privileged)
      PRIVILEGED=false; shift ;;
    --build)
      BUILD_MODE=true; shift ;;
    --no-build)
      BUILD_MODE=false; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -t 0 ]]; then
  echo "=========================================="
  echo " ROS Noetic Docker 开发环境配置"
  echo "=========================================="
  echo "提示：方括号内是默认值，直接按 Enter 即可采用。"
  echo

  while true; do
    current_project_name="${PROJECT_NAME:-$DEFAULT_PROJECT_NAME}"
    read -r -p "Docker 环境名称（例: traj，用于容器和启动器命名） [$current_project_name]: " input
    PROJECT_NAME="${input:-$current_project_name}"
    if [[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
      break
    fi
    echo "名称只能包含字母、数字、下划线、点和连字符，且必须以字母或数字开头。"
  done

  while true; do
    read -r -p "工作空间路径（宿主机与容器使用相同路径） [$CATKIN_WS]: " input
    selected_workspace="$(realpath -m "${input:-$CATKIN_WS}")"
    if [[ -d "$selected_workspace" ]]; then
      CATKIN_WS="$selected_workspace"
      break
    fi
    echo "目录不存在: $selected_workspace"
  done

  echo
  echo "运行环境：local=本机桌面/GUI，remote=远程 SSH/无本地图形会话"
  prompt_choice DEVELOP_ENVIRONMENT "请选择 local/remote" '^(local|remote)$'

  echo
  echo "默认 Shell：bash=兼容稳定（推荐），zsh=菜单补全、自动建议和语法高亮"
  prompt_choice DEFAULT_SHELL "请选择 bash/zsh" '^(bash|zsh)$'

  echo
  echo "GPU 模式：auto=自动检测（推荐），on=强制启用，off=禁用"
  prompt_choice GPU_MODE "请选择 auto/on/off" '^(auto|on|off)$'

  if [[ "$CUDA_VERSION" == "auto" ]]; then
    CUDA_VERSION="${DETECTED_CUDA_VERSION:-none}"
  fi
  echo
  if [[ -n "$DETECTED_CUDA_VERSION" ]]; then
    echo "检测到本机 CUDA Toolkit ${DETECTED_CUDA_VERSION}。"
  else
    echo "未检测到本机 CUDA Toolkit，将禁用 CUDA。"
  fi
  prompt_choice CUDA_VERSION "CUDA Toolkit 版本（例: 12.8；none=禁用）" '^(none|[0-9]+\.[0-9]+)$'
  if [[ "$CUDA_VERSION" == "none" ]]; then
    GPU_MODE=off
  fi

  echo
  echo "硬件权限：启用后映射 /dev，适用于串口、雷达、相机等机器人设备"
  prompt_yes_no PRIVILEGED "启用 privileged 和 /dev 映射"

  if [[ "$BUILD_MODE" == "ask" ]]; then
    BUILD_MODE=true
    echo
    echo "构建镜像：首次使用建议立即构建；选择 n 则只生成 Compose 配置"
    prompt_yes_no BUILD_MODE "生成配置后立即构建镜像"
  fi

  echo
  echo "即将使用以下配置："
  echo "  名称:          $PROJECT_NAME"
  echo "  工作空间:      $CATKIN_WS"
  echo "  运行环境:      $DEVELOP_ENVIRONMENT"
  echo "  默认 Shell:    $DEFAULT_SHELL"
  echo "  GPU 模式:      $GPU_MODE"
  echo "  CUDA Toolkit:  $CUDA_VERSION"
  echo "  privileged:    $PRIVILEGED"
  echo "  立即构建:      $BUILD_MODE"
  echo
  CONFIRM_GENERATE=true
  prompt_yes_no CONFIRM_GENERATE "按以上配置生成 Docker 环境"
  if [[ "$CONFIRM_GENERATE" != "true" ]]; then
    echo "已取消，未生成配置。"
    exit 0
  fi
elif [[ -z "$PROJECT_NAME" ]]; then
  echo "--name is required in non-interactive mode." >&2
  exit 2
fi

[[ "$PROJECT_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || {
  echo "Invalid environment name: $PROJECT_NAME" >&2
  exit 2
}
case "$DEVELOP_ENVIRONMENT" in local|remote) ;; *) echo "Environment must be local or remote." >&2; exit 2 ;; esac
case "$DEFAULT_SHELL" in bash|zsh) ;; *) echo "Shell must be bash or zsh." >&2; exit 2 ;; esac
case "$GPU_MODE" in auto|on|off) ;; *) echo "GPU mode must be auto, on or off." >&2; exit 2 ;; esac

if [[ "$CUDA_VERSION" == "auto" ]]; then
  CUDA_VERSION="${DETECTED_CUDA_VERSION:-none}"
  if [[ -z "$DETECTED_CUDA_VERSION" ]]; then
    echo "Warning: CUDA version was not detected; CUDA is disabled." >&2
  fi
fi
[[ "$CUDA_VERSION" =~ ^(none|[0-9]+\.[0-9]+)$ ]] || {
  echo "CUDA version must be none or use major.minor format, e.g. 12.8." >&2
  exit 2
}

CATKIN_WS="$(realpath -m "$CATKIN_WS")"
if [[ ! -d "$CATKIN_WS" ]]; then
  echo "Workspace does not exist: $CATKIN_WS" >&2
  exit 1
fi

has_nvidia_hardware() {
  command -v nvidia-smi >/dev/null 2>&1 || \
    [[ -e /proc/driver/nvidia/version ]] || \
    { command -v lspci >/dev/null 2>&1 && lspci -d '10de:' | grep -qi nvidia; }
}

ENABLE_GPU=false
case "$GPU_MODE" in
  on) ENABLE_GPU=true ;;
  auto) has_nvidia_hardware && ENABLE_GPU=true ;;
  off) ;;
esac

if [[ "$CUDA_VERSION" == "none" ]]; then
  ENABLE_GPU=false
fi

if "$ENABLE_GPU"; then
  if ! command -v nvidia-ctk >/dev/null 2>&1; then
    echo "Warning: NVIDIA Container Toolkit was not found; run:" >&2
    echo "  ./install-docker-tools-on-ubuntu.sh --gpu on" >&2
  fi
  if ! nvidia-smi >/dev/null 2>&1; then
    echo "Warning: host nvidia-smi is not working; the GPU container will not start until the driver is fixed/rebooted." >&2
  fi
fi

CCACHE_DIR="/var/cache/ccache"
if [[ ! -d "$CCACHE_DIR" ]]; then
  CCACHE_DIR="/tmp/ros-dev-ccache-$HOST_UID"
  mkdir -p "$CCACHE_DIR"
fi

PROJECT_DIR="$SCRIPT_ROOT/dockers/$PROJECT_NAME"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
CONTAINER_NAME="${PROJECT_NAME}_ros_dev"
IMAGE_NAME="ros_dev_env_noetic:${PROJECT_NAME}"
INSTALL_ZSH=false
[[ "$DEFAULT_SHELL" == "zsh" ]] && INSTALL_ZSH=true
mkdir -p "$PROJECT_DIR"

XAUTHORITY_PATH=""
if [[ "$DEVELOP_ENVIRONMENT" == "local" ]]; then
  if [[ -n "${XAUTHORITY:-}" && -f "$XAUTHORITY" ]]; then
    XAUTHORITY_PATH="$XAUTHORITY"
  elif [[ -f "$HOST_HOME_DIR/.Xauthority" ]]; then
    XAUTHORITY_PATH="$HOST_HOME_DIR/.Xauthority"
  fi
fi
XAUTHORITY_ENV_LINE=""
if [[ -n "$XAUTHORITY_PATH" ]]; then
  XAUTHORITY_ENV_LINE="      XAUTHORITY: \"${XAUTHORITY_PATH}\""
fi

cat >"$COMPOSE_FILE" <<EOF
name: ${PROJECT_NAME}

services:
  ros_dev:
    container_name: ${CONTAINER_NAME}
    build:
      context: ../..
      dockerfile: dockers/Dockerfile
      args:
        USER_NAME: ${HOST_USER}
        USER_UID: "${HOST_UID}"
        USER_GID: "${HOST_GID}"
        USER_HOME: ${HOST_HOME_DIR}
        USER_SHELL: ${DEFAULT_SHELL}
        INSTALL_ZSH: "${INSTALL_ZSH}"
        CUDA_VERSION: "${CUDA_VERSION}"
    image: ${IMAGE_NAME}
    working_dir: ${CATKIN_WS}
    stdin_open: true
    tty: true
    network_mode: host
    ipc: host
    cap_add:
      - SYS_PTRACE
    environment:
      CUSTOM_CONTAINER_NAME: "${PROJECT_NAME}"
      DISPLAY: "${HOST_DISPLAY}"
${XAUTHORITY_ENV_LINE}
      QT_X11_NO_MITSHM: "1"
      XMODIFIERS: "${XMODIFIERS:-@im=fcitx}"
      QT_IM_MODULE: "${QT_IM_MODULE:-fcitx}"
      GTK_IM_MODULE: "${GTK_IM_MODULE:-fcitx}"
      NVIDIA_VISIBLE_DEVICES: "all"
      NVIDIA_DRIVER_CAPABILITIES: "compute,utility,graphics,display,video"
    volumes:
      - "${CATKIN_WS}:${CATKIN_WS}"
      - "${CCACHE_DIR}:/var/cache/ccache"
EOF

append_volume_if_exists() {
  local source_path="$1"
  local target_path="${2:-$1}"
  local mount_options="${3:-}"
  if [[ -e "$source_path" ]]; then
    printf '      - "%s:%s%s"\n' "$source_path" "$target_path" "$mount_options" >>"$COMPOSE_FILE"
  fi
}

append_volume_if_exists "$HOST_HOME_DIR/.ssh"
append_volume_if_exists "$HOST_HOME_DIR/.gitconfig"
append_volume_if_exists "$HOST_HOME_DIR/.config/zecol"
append_volume_if_exists "$HOST_HOME_DIR/.config/nvim"
append_volume_if_exists "$HOST_HOME_DIR/.local/share/nvim"
append_volume_if_exists "$HOST_HOME_DIR/.vim"
append_volume_if_exists "$HOST_HOME_DIR/.vimrc"
append_volume_if_exists /etc/machine-id /etc/machine-id :ro
append_volume_if_exists /var/run/dbus/system_bus_socket /var/run/dbus/system_bus_socket

if [[ "$DEVELOP_ENVIRONMENT" == "local" ]]; then
  append_volume_if_exists /tmp/.X11-unix /tmp/.X11-unix :rw
  if [[ -n "$XAUTHORITY_PATH" ]]; then
    append_volume_if_exists "$XAUTHORITY_PATH"
  fi
fi

if "$PRIVILEGED"; then
  cat >>"$COMPOSE_FILE" <<'EOF'
    privileged: true
    devices:
      - /dev:/dev
EOF
fi

if "$ENABLE_GPU"; then
  cat >>"$COMPOSE_FILE" <<'EOF'
    gpus: all
EOF
fi

mkdir -p "$LAUNCHER_DIR"
LAUNCHER_PATH="$LAUNCHER_DIR/ros-dev-env-$PROJECT_NAME"
cat >"$LAUNCHER_PATH" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
COMPOSE_FILE="${COMPOSE_FILE}"
docker compose -f "\$COMPOSE_FILE" up -d
if ((\$# == 0)); then
  exec docker compose -f "\$COMPOSE_FILE" exec ros_dev ${DEFAULT_SHELL}
else
  exec docker compose -f "\$COMPOSE_FILE" exec ros_dev "\$@"
fi
EOF
chmod +x "$LAUNCHER_PATH"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  docker compose -f "$COMPOSE_FILE" config --quiet
  if [[ "$BUILD_MODE" == "true" ]]; then
    docker compose -f "$COMPOSE_FILE" build
  fi
elif [[ "$BUILD_MODE" == "true" ]]; then
  echo "Docker Compose is not installed. Run ./install-docker-tools-on-ubuntu.sh first." >&2
  exit 1
fi

echo "Generated: $COMPOSE_FILE"
echo "Launcher:  $LAUNCHER_PATH"
echo "GPU:       $ENABLE_GPU"
echo "CUDA:      $CUDA_VERSION"
echo
echo "Start with:"
echo "  $LAUNCHER_PATH"
if [[ ":$PATH:" != *":$LAUNCHER_DIR:"* ]]; then
  echo "Add $LAUNCHER_DIR to PATH before using the launcher by name."
fi
