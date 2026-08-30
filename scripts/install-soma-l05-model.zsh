#!/bin/zsh
set -euo pipefail

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_lock="$soma_root/config/soma-dependencies.env"
soma_manifest="$soma_root/config/l05-model.sha256"
soma_plan_only=0
soma_stage=''
soma_model_parent=''

function soma_cleanup() {
  if [[ -n "$soma_stage" \
        && -n "$soma_model_parent" \
        && -d "$soma_stage" \
        && "${soma_stage:h}" == "$soma_model_parent" \
        && "${soma_stage:t}" == .l05-model-stage.* ]]; then
    /bin/rm -rf -- "$soma_stage"
  fi
}
trap soma_cleanup EXIT

function soma_usage() {
  print -r -- 'Usage: scripts/install-soma-l05-model.zsh [--plan]'
}

while (( $# > 0 )); do
  case "$1" in
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

[[ -f "$soma_lock" ]] || { print -u2 -r -- "missing dependency lock: $soma_lock"; exit 2; }
[[ -f "$soma_manifest" ]] || { print -u2 -r -- "missing model manifest: $soma_manifest"; exit 2; }
source "$soma_lock"

soma_support_root=${SOMA_SUPPORT_ROOT:-"$HOME/Library/Application Support/SOMA"}
soma_python=${SOMA_L05_VLM_PYTHON:-"$soma_support_root/venvs/l05/bin/python"}
soma_model_parent=${SOMA_L05_MODEL_PARENT:-"$soma_support_root/models"}
soma_model_root=${SOMA_L05_VLM_MODEL:-"$soma_model_parent/$SOMA_L05_MODEL_DIRECTORY"}

function soma_model_is_valid() {
  [[ "${soma_model_root:t}" == "$SOMA_L05_MODEL_DIRECTORY" \
        && -d "$soma_model_root" ]] \
    && (cd "$soma_model_root" && shasum -a 256 -c "$soma_manifest" >/dev/null 2>&1)
}

if (( soma_plan_only )); then
  print -r -- 'SOMA L0.5 model plan'
  print -r -- "  source: $SOMA_L05_REPOSITORY"
  print -r -- "  revision: $SOMA_L05_REVISION"
  print -r -- "  destination: $soma_model_root"
  print -r -- '  verification: config/l05-model.sha256'
  exit 0
fi

if soma_model_is_valid; then
  print -r -- "L0.5 model is already verified at $soma_model_root"
  exit 0
fi

[[ -x "$soma_python" ]] \
  || { print -u2 -r -- "L0.5 Python environment is unavailable: $soma_python"; exit 2; }
"$soma_python" -c 'import huggingface_hub' >/dev/null 2>&1 \
  || { print -u2 -r -- 'The locked L0.5 environment does not contain huggingface_hub.'; exit 2; }

mkdir -p "$soma_model_parent"
chmod 700 "$soma_support_root" "$soma_model_parent"
soma_stage=$(mktemp -d "$soma_model_parent/.l05-model-stage.XXXXXX")

soma_allow_patterns=(${(f)"$(awk '{ print $2 }' "$soma_manifest")"})
SOMA_DOWNLOAD_REPOSITORY="$SOMA_L05_REPOSITORY" \
SOMA_DOWNLOAD_REVISION="$SOMA_L05_REVISION" \
SOMA_DOWNLOAD_DIRECTORY="$soma_stage" \
SOMA_DOWNLOAD_FILES="${(j.:.)soma_allow_patterns}" \
  "$soma_python" - <<'PY'
import os
import sys

from huggingface_hub import snapshot_download
from huggingface_hub.utils import GatedRepoError, HfHubHTTPError

try:
    snapshot_download(
        repo_id=os.environ["SOMA_DOWNLOAD_REPOSITORY"],
        revision=os.environ["SOMA_DOWNLOAD_REVISION"],
        local_dir=os.environ["SOMA_DOWNLOAD_DIRECTORY"],
        allow_patterns=os.environ["SOMA_DOWNLOAD_FILES"].split(":"),
    )
except (GatedRepoError, HfHubHTTPError) as error:
    print(
        "Unable to download the pinned L0.5 checkpoint. Accept the model terms "
        "and authenticate with 'hf auth login', then rerun setup.",
        file=sys.stderr,
    )
    print(str(error), file=sys.stderr)
    raise SystemExit(2)
PY

(cd "$soma_stage" && shasum -a 256 -c "$soma_manifest") \
  || { print -u2 -r -- 'Downloaded L0.5 model differs from the locked checkpoint.'; exit 2; }

soma_backup="$soma_model_parent/.$SOMA_L05_MODEL_DIRECTORY.backup.$$"
[[ ! -e "$soma_backup" ]] \
  || { print -u2 -r -- "unexpected model backup path: $soma_backup"; exit 2; }
if [[ -e "$soma_model_root" ]]; then
  /bin/mv "$soma_model_root" "$soma_backup"
fi
if /bin/mv "$soma_stage" "$soma_model_root"; then
  soma_stage=''
  chmod -R u=rwX,go= "$soma_model_root"
  if [[ -d "$soma_backup" && "${soma_backup:h}" == "$soma_model_parent" ]]; then
    /bin/rm -rf -- "$soma_backup"
  fi
else
  if [[ -d "$soma_backup" && ! -e "$soma_model_root" ]]; then
    /bin/mv "$soma_backup" "$soma_model_root"
  fi
  print -u2 -r -- 'Could not activate the verified L0.5 model.'
  exit 2
fi

print -r -- "Installed verified L0.5 model at $soma_model_root"
