#!/bin/zsh
set -euo pipefail

soma_model_url='https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip'
soma_archive_sha256='80ffe37d8a5940d59a7384c201a2a38d4741f2f3c51eef46ebb28218a7b0ca2f'
soma_install_root="$HOME/Library/Application Support/SOMA/models/arcface-r50-v1"
soma_installed_model="$soma_install_root/ArcFaceR50.mlmodelc"
soma_script_root="${0:A:h}"
soma_root="${soma_script_root:h}"
soma_lock="$soma_root/config/soma-dependencies.env"
[[ -f "$soma_lock" ]] || { print -u2 -r -- "missing dependency lock: $soma_lock"; exit 2; }
source "$soma_lock"
source "$soma_root/scripts/lib/soma-model-contracts.zsh"

function soma_installed_model_is_valid() {
  [[ -f "$soma_installed_model/model.mil" \
        && -f "$soma_installed_model/weights/weight.bin" \
        && -f "$soma_installed_model/coremldata.bin" \
        && -f "$soma_installed_model/analytics/coremldata.bin" \
        && -f "$soma_installed_model/metadata.json" ]] || return 1
  [[ "$(shasum -a 256 "$soma_installed_model/model.mil" | awk '{print $1}')" == "$SOMA_ARCFACE_MODEL_SHA256" \
        && "$(shasum -a 256 "$soma_installed_model/weights/weight.bin" | awk '{print $1}')" == "$SOMA_ARCFACE_WEIGHTS_SHA256" ]] \
    || return 1
  soma_arcface_metadata_contract_is_valid "$soma_installed_model/metadata.json" || return 1
  xcrun swift -e \
    'import CoreML; import Foundation; _ = try MLModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))' \
    "$soma_installed_model" >/dev/null 2>&1
}

if soma_installed_model_is_valid; then
  print -r -- "ArcFace R50 is already verified at $soma_installed_model"
  exit 0
fi

soma_python=${SOMA_ARCFACE_PYTHON:-$(command -v python3.12 2>/dev/null || true)}
if [[ -z "$soma_python" ]] && command -v brew >/dev/null 2>&1; then
  soma_python_prefix=$(brew --prefix python@3.12 2>/dev/null || true)
  [[ -n "$soma_python_prefix" ]] && soma_python="$soma_python_prefix/bin/python3.12"
fi
if [[ ! -x "$soma_python" \
      || "$("$soma_python" --version 2>&1)" != "Python $SOMA_ARCFACE_PYTHON_VERSION"* ]]; then
  print -u2 -r -- "ArcFace conversion requires Python $SOMA_ARCFACE_PYTHON_VERSION.x; install python@3.12 or set SOMA_ARCFACE_PYTHON."
  exit 2
fi
soma_xcode_build=$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')
if [[ "$soma_xcode_build" != "$SOMA_ARCFACE_XCODE_BUILD" ]]; then
  print -u2 -r -- "ArcFace conversion requires Xcode build $SOMA_ARCFACE_XCODE_BUILD; found ${soma_xcode_build:-unknown}."
  exit 2
fi
soma_work_root="$(mktemp -d /private/tmp/soma-arcface.XXXXXX)"
soma_install_stage=''
function soma_cleanup() {
  if [[ -d "$soma_work_root" \
        && "${soma_work_root:h}" == /private/tmp \
        && "${soma_work_root:t}" == soma-arcface.* ]]; then
    /bin/rm -rf -- "$soma_work_root"
  fi
  if [[ -n "$soma_install_stage" \
        && -d "$soma_install_stage" \
        && "${soma_install_stage:h}" == "$soma_install_root" \
        && "${soma_install_stage:t}" == .ArcFaceR50.stage.* ]]; then
    /bin/rm -rf -- "$soma_install_stage"
  fi
}
trap soma_cleanup EXIT

curl --fail --location --silent --show-error \
  "$soma_model_url" \
  --output "$soma_work_root/buffalo_l.zip"
soma_actual_sha256="$(shasum -a 256 "$soma_work_root/buffalo_l.zip" | awk '{print $1}')"
if [[ "$soma_actual_sha256" != "$soma_archive_sha256" ]]; then
  print -u2 "InsightFace archive hash mismatch"
  exit 1
fi

unzip -qq "$soma_work_root/buffalo_l.zip" w600k_r50.onnx -d "$soma_work_root"
"$soma_python" -m venv "$soma_work_root/venv"
"$soma_work_root/venv/bin/python" -m pip install --quiet "pip==$SOMA_ARCFACE_PIP_VERSION"
"$soma_work_root/venv/bin/python" -m pip install --quiet -r "$soma_root/requirements-arcface.lock.txt"
"$soma_work_root/venv/bin/python" -m pip check
"$soma_work_root/venv/bin/python" \
  "$soma_script_root/convert_arcface_coreml.py" \
  --input "$soma_work_root/w600k_r50.onnx" \
  --output "$soma_work_root/ArcFaceR50.mlpackage"
xcrun coremlcompiler compile \
  "$soma_work_root/ArcFaceR50.mlpackage" \
  "$soma_work_root/compiled" >/dev/null

soma_compiled="$soma_work_root/compiled/ArcFaceR50.mlmodelc"
function soma_verify_compiled_file() {
  local soma_relative="$1"
  local soma_expected="$2"
  local soma_path="$soma_compiled/$soma_relative"
  if [[ ! -f "$soma_path" ]]; then
    print -u2 -r -- "missing compiled ArcFace file: $soma_relative"
    return 1
  fi
  [[ -z "$soma_expected" ]] && return 0
  local soma_actual
  soma_actual=$(shasum -a 256 "$soma_path" | awk '{print $1}')
  if [[ "$soma_actual" != "$soma_expected" ]]; then
    print -u2 -r -- "ArcFace hash mismatch: $soma_relative expected=$soma_expected actual=$soma_actual"
    return 1
  fi
}
soma_compiled_valid=1
soma_verify_compiled_file model.mil "$SOMA_ARCFACE_MODEL_SHA256" || soma_compiled_valid=0
soma_verify_compiled_file weights/weight.bin "$SOMA_ARCFACE_WEIGHTS_SHA256" || soma_compiled_valid=0
soma_verify_compiled_file coremldata.bin '' || soma_compiled_valid=0
soma_verify_compiled_file analytics/coremldata.bin '' || soma_compiled_valid=0
soma_arcface_metadata_contract_is_valid "$soma_compiled/metadata.json" || soma_compiled_valid=0
(( soma_compiled_valid == 1 )) \
  || { print -u2 -r -- 'compiled ArcFace model differs from the locked toolchain output'; exit 2; }
xcrun swift -e \
  'import CoreML; import Foundation; _ = try MLModel(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))' \
  "$soma_compiled" \
  || { print -u2 -r -- 'compiled ArcFace model failed Core ML loading validation'; exit 2; }

mkdir -p "$soma_install_root"
soma_install_stage="$soma_install_root/.ArcFaceR50.stage.$$"
soma_backup="$soma_install_root/.ArcFaceR50.backup.$$"
[[ ! -e "$soma_install_stage" && ! -e "$soma_backup" ]] \
  || { print -u2 -r -- 'unexpected ArcFace staging path'; exit 2; }
/usr/bin/ditto "$soma_compiled" "$soma_install_stage"
if [[ -e "$soma_installed_model" ]]; then
  /bin/mv "$soma_installed_model" "$soma_backup"
fi
if /bin/mv "$soma_install_stage" "$soma_installed_model"; then
  soma_install_stage=''
  if [[ -d "$soma_backup" && "${soma_backup:h}" == "$soma_install_root" ]]; then
    /bin/rm -rf -- "$soma_backup"
  fi
else
  if [[ -d "$soma_backup" && ! -e "$soma_installed_model" ]]; then
    /bin/mv "$soma_backup" "$soma_installed_model"
  fi
  print -u2 -r -- 'Could not activate the verified ArcFace model.'
  exit 2
fi
chmod -R u=rwX,go= "$soma_install_root"
print -r -- "Installed ArcFace R50 at $soma_installed_model"
