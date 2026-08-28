#!/bin/zsh
set -eu

soma_script_dir=${0:A:h}
soma_root=${SOMA_ROOT:-${soma_script_dir:h}}
soma_python=${SOMA_GEOMETRY_PYTHON:-${SOMA_L05_VLM_PYTHON:-"$HOME/Library/Application Support/SOMA/venvs/l05/bin/python"}}

if [[ ! -x "$soma_python" ]]; then
  print -u2 -r -- "Missing geometry-calibration Python runtime: $soma_python"
  print -u2 -r -- 'Set SOMA_GEOMETRY_PYTHON to a Python environment containing scipy and opencv-python.'
  exit 64
fi

if ! "$soma_python" -c 'import cv2, scipy' >/dev/null 2>&1; then
  print -u2 -r -- "Geometry-calibration runtime lacks scipy or opencv-python: $soma_python"
  exit 64
fi

exec "$soma_python" "$soma_root/scripts/soma_camera_geometry_calibrate.py" "$@"
