#!/bin/zsh
set -eu

if (( $# != 2 )); then
  print -u2 -r -- 'Usage: soma-select-gimbal-calibration.zsh <soma-root> <tiny_2_lite|tiny_3_lite>'
  exit 64
fi

soma_calibration_root=$1
soma_calibration_profile=$2

case "$soma_calibration_profile" in
  tiny_2_lite)
    soma_profile_override=${SOMA_TINY2_LITE_EXTERNAL_GIMBAL_CALIBRATION:-}
    soma_profile_default="$soma_calibration_root/config/obsbot/tiny2-lite-gimbal.json"
    ;;
  tiny_3_lite)
    soma_profile_override=${SOMA_TINY3_LITE_EXTERNAL_GIMBAL_CALIBRATION:-}
    soma_profile_default=''
    ;;
  *)
    print -u2 -r -- "Unsupported OBSBOT profile: $soma_calibration_profile"
    exit 64
    ;;
esac

function soma_declared_profile() {
  local soma_candidate=$1
  /usr/bin/plutil -extract deviceProfile raw -o - "$soma_candidate" 2>/dev/null || true
}

function soma_matches_profile() {
  local soma_candidate=$1
  [[ -f "$soma_candidate" ]] || return 1
  local soma_declared
  soma_declared=$(soma_declared_profile "$soma_candidate")
  if [[ -n "$soma_declared" ]]; then
    [[ "$soma_declared" == "$soma_calibration_profile" ]]
    return
  fi
  [[ "$soma_calibration_profile" == 'tiny_2_lite' ]]
}

for soma_candidate in "$soma_profile_override" "${SOMA_EXTERNAL_GIMBAL_CALIBRATION:-}" "$soma_profile_default"; do
  if [[ -n "$soma_candidate" ]] && soma_matches_profile "$soma_candidate"; then
    print -r -- "$soma_candidate"
    exit 0
  fi
done

print -u2 -r -- "No compatible gimbal calibration is available for $soma_calibration_profile."
exit 64
