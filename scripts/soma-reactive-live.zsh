#!/bin/zsh
set -eu

soma_script_dir=${0:A:h}
soma_root=${SOMA_ROOT:-${soma_script_dir:h}}
soma_app_root=${SOMA_APP_ROOT:-"$HOME/Library/Application Support/SOMA/Applications/SOMA Subconscious.app"}
soma_binary="$soma_app_root/Contents/MacOS/soma-subconscious"
soma_runtime_root="$soma_root/artifacts/subconscious/runtime"
soma_launcher_log="$soma_runtime_root/launcher/soma-reactive.log"

export SOMA_ROOT="$soma_root"
export SOMA_APP_ROOT="$soma_app_root"
export SOMA_RUNTIME_ROOT="$soma_runtime_root"

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

# Load the SOMA layer (.env) configuration managed by the Control Center. It
# is sourced so OLLAMA_API_KEY and the layer toggles become process env for the
# runtime below. Owner-only perms are enforced by the Control Center on save.
soma_env_file="$HOME/Library/Application Support/SOMA/.env"
if [[ -f "$soma_env_file" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$soma_env_file"
  set +a
fi
soma_l1_aux_python=${SOMA_L05_VLM_PYTHON:-"$HOME/Library/Application Support/SOMA/venvs/l05/bin/python"}
soma_l1_aux_model=${SOMA_L05_VLM_MODEL:-"$HOME/Library/Application Support/SOMA/models/gemma-4-e2b-it-4bit"}
soma_video_id=${SOMA_VIDEO_ID:-}
soma_audio_id=${SOMA_AUDIO_ID:-}
if [[ -z "$soma_video_id" || -z "$soma_audio_id" ]]; then
  print -u2 -r -- 'SOMA_VIDEO_ID and SOMA_AUDIO_ID must be set in ~/Library/Application Support/SOMA/.env. Run soma-probe --list-formats first.'
  exit 64
fi

# Install the SwiftPM product into one real app bundle so camera, microphone,
# and speech-recognition TCC grants share a stable signed identity.
"$soma_root/scripts/install-soma-subconscious-app.zsh" >/dev/null
# Derive the L1 /api/chat endpoint from the configured host unless it was set
# explicitly (SOMA_L1_OLLAMA_ENDPOINT already resolves in the binary too).
if [[ -n "${OLLAMA_HOST:-}" && -z "${SOMA_L1_OLLAMA_ENDPOINT:-}" ]]; then
  export SOMA_L1_OLLAMA_ENDPOINT="${OLLAMA_HOST%/}/api/chat"
fi

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

soma_geometry_args=()
if [[ -n "${SOMA_CAMERA_GEOMETRY_CALIBRATION:-}" ]]; then
  if [[ ! -f "$SOMA_CAMERA_GEOMETRY_CALIBRATION" ]]; then
    print -u2 -r -- 'SOMA_CAMERA_GEOMETRY_CALIBRATION does not exist.'
    exit 64
  fi
  soma_geometry_args=(--camera-geometry-calibration "$SOMA_CAMERA_GEOMETRY_CALIBRATION")
fi

soma_live_voice_args=()
if [[ "${SOMA_ENABLE_L2_LIVE_VOICE:-1}" == "1" ]]; then
  soma_live_voice_args=(--l2-live-voice)
fi

soma_motion_args=()
if [[ "${SOMA_ENABLE_MOTION:-0}" == "1" ]]; then
  soma_external_calibration=${SOMA_EXTERNAL_GIMBAL_CALIBRATION:-}
  if [[ -z "$soma_external_calibration" || ! -f "$soma_external_calibration" ]]; then
    print -u2 -r -- 'SOMA_ENABLE_MOTION=1 requires SOMA_EXTERNAL_GIMBAL_CALIBRATION to name an existing calibration file.'
    exit 64
  fi
  soma_motion_args=(
    --allow-embodiment-motor-control
    --embodiment-view-directory "$soma_runtime_root/views"
    --allow-camera-motion
    --native-gimbal-helper "$soma_root/.build/soma-live/native/soma-native-track"
    --gimbal-output "$soma_runtime_root/actuator/gimbal.jsonl"
    --gimbal-trace-max-megabytes 32
    --gimbal-trace-retained-files 4
    --allow-native-human-tracking
    --allow-external-gimbal-control
    --external-gimbal-calibration "$soma_external_calibration"
    --allow-autonomous-scan
  )
fi

exec "$soma_binary" \
  --duration 0 \
  --video-id "$soma_video_id" \
  --audio-id "$soma_audio_id" \
  --output "$soma_runtime_root/detail/subconscious.jsonl" \
  --trace-max-megabytes 128 \
  --trace-retained-files 8 \
  --important-output "$soma_runtime_root/important/subconscious-important.jsonl" \
  --important-max-megabytes 16 \
  --important-retained-files 8 \
  "${soma_l05_vlm_args[@]}" \
  "${soma_geometry_args[@]}" \
  "${soma_live_voice_args[@]}" \
  --embodiment-shadow-socket "$soma_runtime_root/ipc/embodiment-shadow.sock" \
  --panorama-output "$soma_runtime_root/panorama/panorama-latest.jpg" \
  --panorama-place-memory "$soma_runtime_root/panorama/place-memory.json" \
  --soma-settings "$HOME/Library/Application Support/SOMA/settings.json" \
  "${soma_motion_args[@]}"
