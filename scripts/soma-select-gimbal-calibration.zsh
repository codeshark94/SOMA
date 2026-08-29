#!/bin/zsh
set -eu

if (( $# != 2 )); then
  print -u2 -r -- 'Usage: soma-select-gimbal-calibration.zsh <soma-root> <obsbot-device-identifier>'
  exit 64
fi

soma_calibration_root=$1
soma_calibration_profile=$2

soma_profile_env_fragment=${soma_calibration_profile//_/-}
soma_profile_env_fragment=${soma_profile_env_fragment//-/_}
soma_profile_env_key="SOMA_OBSBOT_${(U)soma_profile_env_fragment}_EXTERNAL_GIMBAL_CALIBRATION"
soma_profile_override="${(P)soma_profile_env_key:-}"
soma_profile_default="$soma_calibration_root/config/obsbot/${soma_calibration_profile//_/-}-gimbal.json"

function soma_declared_profile() {
  local soma_candidate=$1
  local soma_identifier
  soma_identifier=$(/usr/bin/plutil -extract deviceIdentifier raw -o - "$soma_candidate" 2>/dev/null || true)
  if [[ -n "$soma_identifier" ]]; then
    print -r -- "$soma_identifier"
    return
  fi
  /usr/bin/plutil -extract deviceProfile raw -o - "$soma_candidate" 2>/dev/null || true
}

function soma_matches_profile() {
  local soma_candidate=$1
  [[ -f "$soma_candidate" ]] || return 1
  local soma_declared
  soma_declared=$(soma_declared_profile "$soma_candidate")
  [[ -n "$soma_declared" && "$soma_declared" == "$soma_calibration_profile" ]]
}

for soma_candidate in "$soma_profile_override" "${SOMA_EXTERNAL_GIMBAL_CALIBRATION:-}" "$soma_profile_default"; do
  if [[ -n "$soma_candidate" ]] && soma_matches_profile "$soma_candidate"; then
    print -r -- "$soma_candidate"
    exit 0
  fi
done

print -u2 -r -- "No compatible gimbal calibration is available for $soma_calibration_profile."
exit 64
