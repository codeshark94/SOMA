#!/bin/zsh
set -u

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_mode=${1:---build}
soma_failures=0

if [[ "$soma_mode" != "--build" && "$soma_mode" != "--runtime" ]]; then
  print -u2 -r -- 'Usage: scripts/soma-doctor.zsh [--build|--runtime]'
  exit 64
fi

function soma_ok() {
  print -r -- "ok   $1"
}

function soma_fail() {
  print -u2 -r -- "fail $1"
  (( soma_failures += 1 ))
}

function soma_warn() {
  print -r -- "warn $1"
}

if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
  soma_ok 'Apple Silicon macOS'
else
  soma_fail 'Apple Silicon macOS is required by the bundled OBSBOT SDK integration'
fi

if command -v swift >/dev/null 2>&1; then
  soma_swift_version=$(swift --version 2>/dev/null | head -n 1)
  soma_ok "$soma_swift_version"
else
  soma_fail 'Swift 6 toolchain is unavailable; install current Xcode command-line tools'
fi

if /usr/bin/xcrun --find clang >/dev/null 2>&1; then
  soma_ok 'Xcode command-line tools'
else
  soma_fail 'Xcode command-line tools are unavailable'
fi

soma_opencv_prefix=${SOMA_OPENCV_PREFIX:-}
if [[ -z "$soma_opencv_prefix" ]] && command -v brew >/dev/null 2>&1; then
  soma_opencv_prefix=$(brew --prefix opencv 2>/dev/null || true)
fi
if [[ -z "$soma_opencv_prefix" ]]; then
  for soma_candidate in /opt/homebrew/opt/opencv /usr/local/opt/opencv; do
    if [[ -d "$soma_candidate" ]]; then
      soma_opencv_prefix="$soma_candidate"
      break
    fi
  done
fi
if [[ -n "$soma_opencv_prefix" \
      && -d "$soma_opencv_prefix/include/opencv5" \
      && -d "$soma_opencv_prefix/lib" ]]; then
  soma_ok "OpenCV at $soma_opencv_prefix"
else
  soma_fail 'OpenCV 5 is unavailable; install it with `brew install opencv` or set SOMA_OPENCV_PREFIX'
fi

for soma_resource in \
  Sources/SOMAVADModel/Resources/SileroVAD256ms.mlmodelc \
  Sources/SOMASubconscious/Resources/YOLO11n.mlpackage \
  Sources/SOMASubconscious/Resources/BlazeFaceShortRange.mlpackage; do
  if [[ -e "$soma_root/$soma_resource" ]]; then
    soma_ok "$soma_resource"
  else
    soma_fail "missing model resource: $soma_resource"
  fi
done

if [[ "$soma_mode" == "--runtime" ]]; then
  soma_cmake=${SOMA_CMAKE:-$(command -v cmake 2>/dev/null || true)}
  if [[ -n "$soma_cmake" && -x "$soma_cmake" ]]; then
    soma_ok "CMake at $soma_cmake"
  else
    soma_fail 'CMake is unavailable; install it with `brew install cmake` or set SOMA_CMAKE'
  fi

  soma_sdk_root=${SOMA_OBSBOT_SDK_ROOT:-"$soma_root/Reference/SDK/libdev_v2.1.0_8"}
  soma_sdk_library=''
  for soma_candidate in \
    "$soma_sdk_root/macos/arm64-release/libdev.dylib" \
    "$soma_sdk_root/macos/macos/arm64-release/libdev.dylib"; do
    if [[ -f "$soma_candidate" ]]; then
      soma_sdk_library="$soma_candidate"
      break
    fi
  done
  if [[ -f "$soma_sdk_root/include/dev/devs.hpp" && -n "$soma_sdk_library" ]]; then
    soma_ok "OBSBOT SDK at $soma_sdk_root"
  else
    soma_fail 'OBSBOT libdev_v2.1.0_8 SDK is unavailable; restore Reference/SDK or set SOMA_OBSBOT_SDK_ROOT'
  fi

  soma_codex=${SOMA_CODEX_BINARY:-}
  if [[ -z "$soma_codex" && -x /Applications/Codex.app/Contents/Resources/codex ]]; then
    soma_codex=/Applications/Codex.app/Contents/Resources/codex
  fi
  if [[ -z "$soma_codex" ]]; then
    soma_codex=$(command -v codex 2>/dev/null || true)
  fi
  if [[ -n "$soma_codex" && -x "$soma_codex" ]]; then
    soma_ok "Codex at $soma_codex"
  else
    soma_warn 'Codex is unavailable; L0 can run, but L2 Live Voice cannot open'
  fi

  soma_env_file="$HOME/Library/Application Support/SOMA/.env"
  if [[ -f "$soma_env_file" ]]; then
    soma_ok "$soma_env_file"
  else
    soma_warn "runtime configuration is not installed at $soma_env_file"
  fi
fi

if (( soma_failures > 0 )); then
  print -u2 -r -- "SOMA preflight failed with $soma_failures blocking issue(s)."
  exit 1
fi

print -r -- "SOMA ${soma_mode#--} prerequisites are ready."
