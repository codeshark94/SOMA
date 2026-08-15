#!/bin/zsh
set -eu

soma_root=/Users/seungyeop/workspace/Research/SOMA
soma_binary='/Users/seungyeop/Library/Application Support/SOMA/Applications/SOMA Subconscious.app/Contents/MacOS/soma-subconscious'
soma_l1_aux_python='/Users/seungyeop/Library/Application Support/SOMA/venvs/l05/bin/python'
soma_l1_aux_model='/Users/seungyeop/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit'
soma_runtime_root="$soma_root/artifacts/subconscious/runtime"
soma_launcher_log="$soma_runtime_root/launcher/soma-reactive.log"

mkdir -p \
  "$soma_runtime_root/detail" \
  "$soma_runtime_root/important" \
  "$soma_runtime_root/actuator" \
  "$soma_runtime_root/ipc" \
  "$soma_runtime_root/views" \
  "$soma_runtime_root/panorama" \
  "$soma_runtime_root/launcher"
chmod 700 "$soma_runtime_root/ipc"
chmod 700 "$soma_runtime_root/views"

# Startup and crash output is normally quiet. Rotate it before each launch so
# failures that occur before the JSONL writers start remain bounded.
soma_launcher_max_bytes=1048576
soma_launcher_retained_files=4
if [[ -f "$soma_launcher_log" ]] && (( $(stat -f %z "$soma_launcher_log") >= soma_launcher_max_bytes )); then
  for ((soma_index = soma_launcher_retained_files - 2; soma_index >= 1; soma_index--)); do
    if [[ -f "$soma_launcher_log.$soma_index" ]]; then
      mv "$soma_launcher_log.$soma_index" "$soma_launcher_log.$((soma_index + 1))"
    fi
  done
  mv "$soma_launcher_log" "$soma_launcher_log.1"
fi
exec >>"$soma_launcher_log" 2>&1

# Install the SwiftPM product into one real app bundle so camera, microphone,
# and speech-recognition TCC grants share a stable signed identity.
"$soma_root/scripts/install-soma-subconscious-app.zsh" >/dev/null

# The local E2B worker is a visual audit tool. It is intentionally opt-in:
# continuous inference adds multi-gigabyte unified-memory pressure without
# participating in L0 fixation, social decisions, or the L2 conversation path.
soma_l05_vlm_args=()
if [[ "${SOMA_ENABLE_L05_VLM:-0}" == "1" ]]; then
  soma_l05_vlm_args=(
    --l1-auxiliary-vlm-python "$soma_l1_aux_python"
    --l1-auxiliary-vlm-worker "$soma_root/scripts/soma_l1_auxiliary_vlm_worker.py"
    --l1-auxiliary-vlm-model "$soma_l1_aux_model"
  )
fi

exec "$soma_binary" \
  --duration 0 \
  --video-id 0x31000003564fef9 \
  --audio-id 'AppleUSBAudioEngine:Remo Tech Co., Ltd.:OBSBOT Tiny 2 Lite:3100000:3' \
  --output "$soma_runtime_root/detail/subconscious.jsonl" \
  --trace-max-megabytes 128 \
  --trace-retained-files 8 \
  --important-output "$soma_runtime_root/important/subconscious-important.jsonl" \
  --important-max-megabytes 16 \
  --important-retained-files 8 \
  "${soma_l05_vlm_args[@]}" \
  --embodiment-shadow-socket "$soma_runtime_root/ipc/embodiment-shadow.sock" \
  --allow-embodiment-motor-control \
  --embodiment-view-directory "$soma_runtime_root/views" \
  --panorama-output "$soma_runtime_root/panorama/panorama-latest.jpg" \
  --panorama-place-memory "$soma_runtime_root/panorama/place-memory.json" \
  --soma-settings '/Users/seungyeop/Library/Application Support/SOMA/settings.json' \
  --camera-geometry-calibration "$soma_root/artifacts/subconscious/camera-geometry-tiny2lite-20260815.json" \
  --l2-live-voice \
  --allow-camera-motion \
  --native-gimbal-helper "$soma_root/.build/soma-live/native/soma-native-track" \
  --gimbal-output "$soma_runtime_root/actuator/gimbal.jsonl" \
  --gimbal-trace-max-megabytes 32 \
  --gimbal-trace-retained-files 4 \
  --allow-native-human-tracking \
  --allow-external-gimbal-control \
  --external-gimbal-calibration "$soma_root/artifacts/subconscious/p7-reactive-robust-r8-calibration-20260814.json" \
  --allow-autonomous-scan
