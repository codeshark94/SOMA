#!/bin/zsh
set -euo pipefail

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_lock="$soma_root/config/soma-dependencies.env"
soma_with_l05=0
soma_enable_motion=0
soma_plan_only=0
soma_tool_path='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
soma_env_stage=''

function soma_cleanup() {
  if [[ -n "$soma_env_stage" \
        && -f "$soma_env_stage" \
        && "${soma_env_stage:h}" == "$HOME/Library/Application Support/SOMA" \
        && "${soma_env_stage:t}" == .env.* ]]; then
    /bin/rm -f -- "$soma_env_stage"
  fi
}
trap soma_cleanup EXIT

function soma_usage() {
  print -r -- 'Usage: scripts/setup-soma.zsh [--with-l05] [--enable-motion] [--plan]'
}

while (( $# > 0 )); do
  case "$1" in
    --with-l05)
      soma_with_l05=1
      shift
      ;;
    --enable-motion)
      soma_enable_motion=1
      shift
      ;;
    --plan)
      soma_plan_only=1
      shift
      ;;
    -h|--help)
      soma_usage
      exit 0
      ;;
    *)
      soma_usage >&2
      exit 64
      ;;
  esac
done

[[ -f "$soma_lock" ]] || { print -u2 -r -- "Missing dependency contract: $soma_lock"; exit 2; }
source "$soma_lock"

function soma_find_ollama() {
  local soma_candidate
  soma_candidate=$(PATH="$soma_tool_path" command -v ollama 2>/dev/null || true)
  if [[ -z "$soma_candidate" && -x /Applications/Ollama.app/Contents/Resources/ollama ]]; then
    soma_candidate=/Applications/Ollama.app/Contents/Resources/ollama
  fi
  print -r -- "$soma_candidate"
}

soma_bootstrap_arguments=()
if (( soma_with_l05 )); then
  soma_bootstrap_arguments+=(--with-l05)
fi
soma_cmake=$(PATH="$soma_tool_path" command -v cmake 2>/dev/null || true)
soma_opencv_ready=0
for soma_opencv_root in /opt/homebrew/opt/opencv /usr/local/opt/opencv; do
  if [[ -d "$soma_opencv_root/include/opencv5" ]]; then
    soma_opencv_ready=1
    break
  fi
done
soma_ollama=$(soma_find_ollama)
soma_skip_brew=0
if [[ -n "$soma_cmake" && -x "$soma_cmake" \
      && $soma_opencv_ready == 1 \
      && -n "$soma_ollama" && -x "$soma_ollama" ]]; then
  soma_skip_brew=1
  soma_bootstrap_arguments+=(--skip-brew)
fi

if (( soma_plan_only )); then
  print -r -- 'SOMA setup plan'
  print -r -- "  repository: $soma_root"
  print -r -- '  OBSBOT control: built-in open UVC/XU driver'
  print -r -- "  L0.5 environment: $([[ $soma_with_l05 == 1 ]] && print install || print preserve)"
  print -r -- "  physical motion: $([[ $soma_enable_motion == 1 ]] && print enable || print preserve)"
  print -r -- "  Homebrew dependencies: $([[ $soma_skip_brew == 1 ]] && print already-present || print install)"
  print -r -- "  L1 model: $SOMA_DEFAULT_L1_MODEL"
  print -r -- "  signing identity: $SOMA_CODESIGN_IDENTITY_NAME"
  print -r -- '  actions: bootstrap, model provisioning, tests, runtime doctor, signed app installation, process verification'
  exit 0
fi

print -r -- '[1/6] Preparing locked dependencies'
"$soma_root/scripts/bootstrap-soma.zsh" "${soma_bootstrap_arguments[@]}"

if (( soma_enable_motion )); then
  soma_env_file="$HOME/Library/Application Support/SOMA/.env"
  soma_env_stage=$(mktemp "${soma_env_file:h}/.env.XXXXXX")
  /usr/bin/awk -v key='SOMA_ENABLE_MOTION' -v value='1' '
    BEGIN { written = 0 }
    index($0, key "=") == 1 {
      if (!written) print key "=" value
      written = 1
      next
    }
    { print }
    END { if (!written) print key "=" value }
  ' "$soma_env_file" > "$soma_env_stage"
  chmod 600 "$soma_env_stage"
  /bin/mv -f "$soma_env_stage" "$soma_env_file"
  soma_env_stage=''
fi

if ! /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -Fq "$SOMA_CODESIGN_IDENTITY_NAME"; then
  print -u2 -r -- "Create the '$SOMA_CODESIGN_IDENTITY_NAME' Code Signing certificate in Keychain Access, then rerun this command."
  /usr/bin/open -a 'Keychain Access' >/dev/null 2>&1 || true
  exit 3
fi

print -r -- '[2/6] Ensuring the L1 model is available'
soma_ollama=$(soma_find_ollama)
[[ -n "$soma_ollama" && -x "$soma_ollama" ]] \
  || { print -u2 -r -- 'Ollama was not installed by bootstrap.'; exit 2; }
if ! "$soma_ollama" list >/dev/null 2>&1; then
  /usr/bin/open -gj /Applications/Ollama.app >/dev/null 2>&1 || true
  soma_ollama_ready=0
  for _ in {1..30}; do
    if "$soma_ollama" list >/dev/null 2>&1; then
      soma_ollama_ready=1
      break
    fi
    sleep 1
  done
  (( soma_ollama_ready == 1 )) \
    || { print -u2 -r -- 'Ollama did not become ready within 30 seconds.'; exit 2; }
fi
if ! "$soma_ollama" list | /usr/bin/awk 'NR > 1 {print $1}' \
    | /usr/bin/grep -Fxq "$SOMA_DEFAULT_L1_MODEL"; then
  "$soma_ollama" pull "$SOMA_DEFAULT_L1_MODEL"
fi

print -r -- '[3/6] Running the verification suite'
/usr/bin/env swift test --package-path "$soma_root"
/usr/bin/env swift run --package-path "$soma_root" soma-core-check

print -r -- '[4/6] Checking runtime prerequisites'
"$soma_root/scripts/soma-doctor.zsh" --runtime

print -r -- '[5/6] Installing the signed local application'
"$soma_root/scripts/install-soma-subconscious-app.zsh"

print -r -- '[6/6] Verifying the active runtime'
"$soma_root/scripts/soma.zsh" status
soma_app_binary="$HOME/Library/Application Support/SOMA/Applications/SOMA Subconscious.app/Contents/MacOS/soma-subconscious"
soma_runtime_pid=''
for _ in {1..45}; do
  soma_runtime_pid=$(/bin/ps -axo pid=,command= | /usr/bin/awk -v binary="$soma_app_binary" '
    {
      pid = $1
      sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
      if (match_pid == "" && ($0 == binary || index($0, binary " ") == 1)) {
        match_pid = pid
      }
    }
    END { if (match_pid != "") print match_pid }
  ')
  [[ -n "$soma_runtime_pid" ]] && break
  sleep 1
done
[[ -n "$soma_runtime_pid" ]] \
  || { print -u2 -r -- 'The LaunchAgent loaded, but the SOMA runtime process did not remain active.'; exit 2; }

print -r -- "SOMA setup complete (runtime pid $soma_runtime_pid)."
print -r -- 'If macOS prompts, grant Camera, Microphone, Speech Recognition, and Accessibility access.'
