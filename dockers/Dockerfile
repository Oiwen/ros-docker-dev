FROM osrf/ros:noetic-desktop-full AS ros_generic

ARG USER_NAME=developer
ARG USER_UID=1000
ARG USER_GID=1000
ARG USER_HOME=/home/developer
ARG USER_SHELL=bash
ARG INSTALL_ZSH=false
ARG CUDA_VERSION=none

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CUDA_HOME=/usr/local/cuda \
    PATH=/usr/local/cuda/bin:${PATH} \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics,display,video \
    QT_X11_NO_MITSHM=1 \
    CUSTOM_CONTAINER_NAME=ros-dev-env

# NVIDIA's container runtime injects the host driver at run time. Installing a
# host-specific libnvidia-gl version here would make the image non-portable.
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash-completion \
      ca-certificates \
      curl \
      git \
      libgl1 \
      libglvnd0 \
      libvulkan1 \
      mesa-utils \
      python3-pip \
      sudo \
      tini \
      vulkan-tools \
    && if [ "$INSTALL_ZSH" = "true" ]; then apt-get install -y --no-install-recommends \
      zsh \
      zsh-autosuggestions \
      zsh-syntax-highlighting; fi \
    && rm -rf /var/lib/apt/lists/*

# Install the requested CUDA toolchain in the generic image. CUDA is omitted
# when detection in generate.sh supplies CUDA_VERSION=none.
RUN if [ "$CUDA_VERSION" = "none" ]; then \
      echo "CUDA Toolkit disabled"; \
    else \
      CUDA_APT_VERSION="$(printf '%s' "$CUDA_VERSION" | tr '.' '-')" \
      && curl -fsSLo /tmp/cuda-keyring.deb \
        https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/cuda-keyring_1.1-1_all.deb \
      && dpkg -i /tmp/cuda-keyring.deb \
      && rm -f /tmp/cuda-keyring.deb \
      && apt-get update \
      && apt-get install -y --no-install-recommends \
        "cuda-toolkit-${CUDA_APT_VERSION}" \
      && rm -rf /var/lib/apt/lists/*; \
    fi

COPY dockers/shell-colors.bash /etc/ros-dev-env/shell-colors.bash
COPY dockers/shell-colors.zsh /etc/ros-dev-env/shell-colors.zsh

RUN if getent group "$USER_GID" >/dev/null; then \
      EXISTING_GROUP="$(getent group "$USER_GID" | cut -d: -f1)"; \
    else \
      groupadd --gid "$USER_GID" "$USER_NAME"; \
      EXISTING_GROUP="$USER_NAME"; \
    fi \
    && useradd --uid "$USER_UID" --gid "$EXISTING_GROUP" --create-home \
      --home-dir "$USER_HOME" --shell "/bin/$USER_SHELL" "$USER_NAME" \
    && echo "$USER_NAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$USER_NAME" \
    && chmod 0440 "/etc/sudoers.d/$USER_NAME" \
    && mkdir -p "$USER_HOME/.cache" "$USER_HOME/.config" "$USER_HOME/.local" \
    && printf '\nsource /opt/ros/noetic/setup.bash\nsource /etc/ros-dev-env/shell-colors.bash\n' >> "$USER_HOME/.bashrc" \
    && if [ "$INSTALL_ZSH" = "true" ]; then printf '\nsource /opt/ros/noetic/setup.zsh\nsource /etc/ros-dev-env/shell-colors.zsh\n' >> "$USER_HOME/.zshrc"; fi \
    && chown -R "$USER_UID:$USER_GID" "$USER_HOME"

COPY dockers/ros-entrypoint.sh /usr/local/bin/ros-entrypoint
RUN chmod 0755 /usr/local/bin/ros-entrypoint

ENV DEBIAN_FRONTEND= \
    HOME=${USER_HOME}

USER ${USER_NAME}
WORKDIR ${USER_HOME}

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ros-entrypoint"]
CMD ["sleep", "infinity"]


# NeuralTraj adds only project-specific build and ROS dependencies. Select this
# stage with `build.target: neuraltraj` in the project Compose file.
FROM ros_generic AS neuraltraj

ARG USER_NAME=developer

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      libeigen3-dev \
      libompl-dev \
      libopencv-dev \
      libpcl-dev \
      ros-noetic-cmake-modules \
      ros-noetic-cv-bridge \
      ros-noetic-pcl-conversions \
      ros-noetic-pcl-ros \
      ros-noetic-tf \
    && rm -rf /var/lib/apt/lists/*

USER ${USER_NAME}


# Keep the generic ROS + CUDA environment as the default build target.
FROM ros_generic AS generic
