#!/usr/bin/env bash
set -e

if [[ -r /opt/ros/noetic/setup.bash ]]; then
  # shellcheck source=/dev/null
  source /opt/ros/noetic/setup.bash
fi

exec "$@"
