# ros-docker-dev

可复用的 ROS Noetic Docker 开发环境，支持本地图形界面、机器人设备映射，以及
可选的 NVIDIA GPU 和 CUDA Toolkit。显卡驱动保留在宿主机，容器通过 NVIDIA
Container Toolkit 使用它。

## 1. 安装 Docker 和 NVIDIA 容器运行时

宿主机需先装好可用的 NVIDIA 驱动，`nvidia-smi` 应能正常显示显卡信息。安装脚本
不使用交互提示，通过参数控制 GPU 支持和安装后测试：

```bash
./install-docker-tools-on-ubuntu.sh --gpu on --test
```

如果 Docker 官方源连接被重置，可以显式使用清华 TUNA 镜像：

```bash
./install-docker-tools-on-ubuntu.sh --docker-source tuna --gpu on --test
```

默认的 `--docker-source auto` 会先尝试官方源，失败后自动切换到 TUNA 镜像；
下载密钥时保留当前用户的代理环境，再通过 sudo 安装到系统目录。

脚本会安装 Docker Engine、Buildx、Compose 插件和 NVIDIA Container Toolkit，
并配置 Docker runtime。安装后若提示用户组发生变化，请注销并重新登录。

没有 NVIDIA 显卡时可使用：

```bash
./install-docker-tools-on-ubuntu.sh --gpu off --test
```

默认的 `--gpu auto` 会在检测到 NVIDIA 硬件或驱动时自动启用 GPU 支持。

## 2. 生成开发环境

直接运行生成脚本进入交互流程：

```bash
./generate.sh
```

脚本会依次询问环境名称、工作空间、local/remote、Shell、GPU、CUDA Toolkit
版本、特权模式以及是否立即构建。CUDA 版本会优先从本机 `nvcc` 自动识别，也可
在交互过程中覆盖。每项都会显示可选值、用途和默认值：

- 环境名称：`traj`
- 工作空间：项目根目录
- 运行环境：`local`
- Shell：`bash`
- GPU：`auto`
- CUDA Toolkit：自动识别，无法识别时设为 `none`，不安装 CUDA 且不启用 GPU
- privileged 和 `/dev` 映射：开启
- 立即构建镜像：开启

写入文件前还会显示完整配置摘要供最终确认。

也可以通过参数进行非交互式生成和构建：

```bash
./generate.sh \
  --name traj \
  --workspace /home/wen/Projects/DPtraj \
  --environment local \
  --shell bash \
  --gpu on \
  --cuda-version 12.8 \
  --build
```

非交互模式省略 `--cuda-version` 时同样会自动识别。识别顺序为本机 `nvcc`、
`/usr/local/cuda` 安装目录、`nvidia-smi`；生成的版本通过 Compose 构建参数传入
Dockerfile。三种方式均无法识别时传入 `none`，镜像跳过 CUDA Toolkit 安装，
Compose 也不会启用 GPU。可以显式使用 `--cuda-version none` 禁用 CUDA。

不带参数运行时，脚本会交互式询问配置。生成的 Compose 文件位于
`dockers/<name>/docker-compose.yml`，启动器位于 `~/.local/bin/ros-dev-env-<name>`。

启动并进入容器：

```bash
ros-dev-env-traj
```

也可以直接执行容器内命令：

```bash
ros-dev-env-traj nvidia-smi
ros-dev-env-traj glxinfo -B
```

镜像会为 Bash 和 Zsh 永久配置彩色 `ls`、`ll`、`la`、`l`、彩色命令提示符、
Tab 命令/参数补全和历史记录搜索。Zsh 还会启用菜单补全、自动建议和命令语法
高亮。修改 Dockerfile 后需要重新构建镜像并重建容器才能生效。

默认保留 `privileged` 和 `/dev` 映射，方便 ROS 访问串口、雷达等硬件。只需要纯
软件环境时，可在生成配置时加 `--no-privileged`。

## 常见问题

- 宿主机 `nvidia-smi` 失败：先修复或重启宿主机 NVIDIA 驱动，容器运行时无法代替驱动。
- 提示找不到 `nvidia-ctk`：重新运行安装脚本并指定 `--gpu on`。
- RViz/GUI 无法显示：使用 `--environment local` 重新生成，确认 `DISPLAY` 和
  `XAUTHORITY` 在当前图形会话中有效。
- Docker socket 权限不足：注销后重新登录，或临时执行 `newgrp docker`。
