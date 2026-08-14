#!/bin/zsh
set -eu

soma_root=/Users/seungyeop/workspace/Research/SOMA
soma_binary="$soma_root/.build/soma-live/arm64-apple-macosx/debug/soma-subconscious"
soma_codesign_identity='SOMA Local Persistent Code Signing'
soma_l05_python='/Users/seungyeop/Library/Application Support/SOMA/venvs/l05/bin/python'
soma_l05_model='/Users/seungyeop/Library/Application Support/SOMA/models/gemma-4-e4b-it-nvfp4'
run_id="$(date +%Y%m%dT%H%M%S)-$$"

# SwiftPM replaces a signature after a rebuild. Keep the camera client bound to
# the same local identity and identifier that has already received its macOS
# permissions; a correctly signed binary takes this no-op branch on restart.
soma_signing_info="$(/usr/bin/codesign -dvv "$soma_binary" 2>&1 || true)"
soma_signature_valid=0
if /usr/bin/codesign --verify --strict --verbose=0 "$soma_binary" >/dev/null 2>&1; then
  soma_signature_valid=1
fi
if [[ "$soma_signature_valid" -ne 1 || "$soma_signing_info" != *"Identifier=com.soma.subconscious"* || "$soma_signing_info" != *"Authority=$soma_codesign_identity"* ]]; then
  /usr/bin/codesign --force --sign "$soma_codesign_identity" \
    --identifier com.soma.subconscious --timestamp=none "$soma_binary"
fi

exec "$soma_binary" \
  --duration 0 \
  --video-id 0x31000003564fef9 \
  --audio-id 'AppleUSBAudioEngine:Remo Tech Co., Ltd.:OBSBOT Tiny 2 Lite:3100000:3' \
  --output "$soma_root/artifacts/subconscious/p7-reactive-live-$run_id.jsonl" \
  --face-lock-diagnostics "$soma_root/artifacts/subconscious/face-lock-diagnostics-$run_id" \
  --l05-vlm-python "$soma_l05_python" \
  --l05-vlm-worker "$soma_root/scripts/soma_l05_vlm_worker.py" \
  --l05-vlm-model "$soma_l05_model" \
  --allow-camera-motion \
  --native-gimbal-helper "$soma_root/.build/soma-live/native/soma-native-track" \
  --gimbal-output "$soma_root/artifacts/subconscious/p7-reactive-live-actuator-$run_id.jsonl" \
  --allow-native-human-tracking \
  --allow-external-gimbal-control \
  --external-gimbal-calibration "$soma_root/artifacts/subconscious/p7-reactive-robust-r8-calibration-20260814.json" \
  --allow-autonomous-scan
