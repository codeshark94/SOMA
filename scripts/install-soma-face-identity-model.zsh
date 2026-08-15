#!/bin/zsh
set -euo pipefail

soma_model_url='https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip'
soma_archive_sha256='80ffe37d8a5940d59a7384c201a2a38d4741f2f3c51eef46ebb28218a7b0ca2f'
soma_install_root="$HOME/Library/Application Support/SOMA/models/arcface-r50-v1"
soma_script_root="${0:A:h}"
soma_work_root="$(mktemp -d /private/tmp/soma-arcface.XXXXXX)"
trap 'rm -rf -- "$soma_work_root"' EXIT

curl --fail --location --silent --show-error \
  "$soma_model_url" \
  --output "$soma_work_root/buffalo_l.zip"
soma_actual_sha256="$(shasum -a 256 "$soma_work_root/buffalo_l.zip" | awk '{print $1}')"
if [[ "$soma_actual_sha256" != "$soma_archive_sha256" ]]; then
  print -u2 "InsightFace archive hash mismatch"
  exit 1
fi

unzip -qq "$soma_work_root/buffalo_l.zip" w600k_r50.onnx -d "$soma_work_root"
python3 -m venv "$soma_work_root/venv"
"$soma_work_root/venv/bin/pip" install --quiet \
  'numpy==1.26.4' \
  'onnx==1.22.0' \
  'onnx2torch==1.5.15' \
  'coremltools==9.0' \
  'torch==2.13.0' \
  'torchvision==0.28.0'
"$soma_work_root/venv/bin/python" \
  "$soma_script_root/convert_arcface_coreml.py" \
  --input "$soma_work_root/w600k_r50.onnx" \
  --output "$soma_work_root/ArcFaceR50.mlpackage"
xcrun coremlcompiler compile \
  "$soma_work_root/ArcFaceR50.mlpackage" \
  "$soma_work_root/compiled" >/dev/null

mkdir -p "$soma_install_root"
rm -rf -- "$soma_install_root/ArcFaceR50.mlmodelc"
cp -R "$soma_work_root/compiled/ArcFaceR50.mlmodelc" "$soma_install_root/ArcFaceR50.mlmodelc"
chmod -R u=rwX,go= "$soma_install_root"
print "Installed ArcFace R50 at $soma_install_root/ArcFaceR50.mlmodelc"
