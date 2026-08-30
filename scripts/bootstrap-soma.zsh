#!/bin/zsh
set -euo pipefail

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_lock="$soma_root/config/soma-dependencies.env"
soma_skip_brew=0
soma_with_l05=0
soma_l05_stage=''
soma_l05_parent=''

function soma_cleanup() {
  if [[ -n "$soma_l05_stage" \
        && -n "$soma_l05_parent" \
        && -d "$soma_l05_stage" \
        && "${soma_l05_stage:h}" == "$soma_l05_parent" \
        && "${soma_l05_stage:t}" == .l05-stage.* ]]; then
    /bin/rm -rf -- "$soma_l05_stage"
  fi
}
trap soma_cleanup EXIT

function soma_usage() {
  print -u2 -r -- 'Usage: scripts/bootstrap-soma.zsh [--with-l05] [--skip-brew]'
}

while (( $# > 0 )); do
  case "$1" in
    --with-l05)
      soma_with_l05=1
      shift
      ;;
    --skip-brew)
      soma_skip_brew=1
      shift
      ;;
    *)
      soma_usage
      exit 64
      ;;
  esac
done

[[ -f "$soma_lock" ]] || { print -u2 -r -- "missing dependency lock: $soma_lock"; exit 2; }
source "$soma_lock"
autoload -Uz is-at-least

if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  print -u2 -r -- 'SOMA full runtime requires Apple Silicon macOS.'
  exit 2
fi

soma_macos_version=$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)
if [[ -z "$soma_macos_version" ]] || ! is-at-least "$SOMA_MIN_RUNTIME_MACOS_VERSION" "$soma_macos_version"; then
  print -u2 -r -- "SOMA full runtime requires macOS $SOMA_MIN_RUNTIME_MACOS_VERSION or newer; found ${soma_macos_version:-unknown}."
  exit 2
fi

if (( ! soma_skip_brew )); then
  soma_brew=$(command -v brew 2>/dev/null || true)
  if [[ -z "$soma_brew" ]]; then
    print -u2 -r -- 'Homebrew is required. Install it from https://brew.sh and rerun this command.'
    exit 2
  fi
  "$soma_brew" bundle install --no-upgrade --file "$soma_root/Brewfile"
fi

soma_support_root="$HOME/Library/Application Support/SOMA"
soma_env_file="$soma_support_root/.env"
mkdir -p "$soma_support_root"
chmod 700 "$soma_support_root"
if [[ ! -f "$soma_env_file" ]]; then
  /usr/bin/ditto "$soma_root/config/soma.env.example" "$soma_env_file"
  print -r -- "Created runtime configuration at $soma_env_file"
fi
chmod 600 "$soma_env_file"

if (( soma_with_l05 )); then
  if ! is-at-least "$SOMA_MIN_L05_MACOS_VERSION" "$soma_macos_version"; then
    print -u2 -r -- "The locked L0.5 MLX wheels require macOS $SOMA_MIN_L05_MACOS_VERSION or newer; found $soma_macos_version."
    exit 2
  fi
  soma_python=$(command -v python3.12 2>/dev/null || true)
  if [[ -z "$soma_python" ]]; then
    if (( soma_skip_brew )); then
      print -u2 -r -- 'Python 3.12 is unavailable and --skip-brew forbids installing it.'
      exit 2
    fi
    if command -v brew >/dev/null 2>&1; then
      brew install python@3.12
      soma_python="$(brew --prefix python@3.12)/bin/python3.12"
    fi
  fi
  [[ -x "$soma_python" ]] || { print -u2 -r -- 'Python 3.12 is required for --with-l05.'; exit 2; }
  soma_l05_parent="$soma_support_root/venvs"
  soma_venv="$soma_l05_parent/l05"
  mkdir -p "$soma_l05_parent"
  chmod 700 "$soma_l05_parent"
  soma_l05_expected=$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$soma_root/requirements-l05.lock.txt" | LC_ALL=C sort -f)
  soma_existing_l05_valid=0
  if [[ -x "$soma_venv/bin/python" ]]; then
    soma_existing_python_version=$("$soma_venv/bin/python" --version 2>&1)
    soma_existing_pip_version=$("$soma_venv/bin/python" -m pip --version 2>/dev/null | sed -nE 's/^pip ([0-9]+(\.[0-9]+){1,2}).*/\1/p')
    soma_existing_l05_actual=$("$soma_venv/bin/python" -m pip freeze --exclude-editable 2>/dev/null | LC_ALL=C sort -f)
    if [[ "$soma_existing_python_version" == "Python $SOMA_L05_PYTHON_VERSION"* \
          && "$soma_existing_pip_version" == "$SOMA_L05_PIP_VERSION" \
          && "$soma_existing_l05_actual" == "$soma_l05_expected" ]]; then
      soma_existing_l05_valid=1
    fi
  fi

  if (( soma_existing_l05_valid == 1 )); then
    print -r -- "L0.5 Python environment is already verified at $soma_venv"
  else
    soma_l05_stage=$(mktemp -d "$soma_l05_parent/.l05-stage.XXXXXX")
    "$soma_python" -m venv "$soma_l05_stage"
    "$soma_l05_stage/bin/python" -m pip install "pip==$SOMA_L05_PIP_VERSION"
    "$soma_l05_stage/bin/python" -m pip install -r "$soma_root/requirements-l05.lock.txt"
    "$soma_l05_stage/bin/python" -m pip check
    soma_l05_actual=$("$soma_l05_stage/bin/python" -m pip freeze --exclude-editable | LC_ALL=C sort -f)
    [[ "$soma_l05_actual" == "$soma_l05_expected" ]] \
      || { print -u2 -r -- 'staged L0.5 environment differs from requirements-l05.lock.txt'; exit 2; }

    soma_l05_backup="$soma_l05_parent/.l05-backup.$$"
    [[ ! -e "$soma_l05_backup" ]] || { print -u2 -r -- "unexpected L0.5 backup path: $soma_l05_backup"; exit 2; }
    if [[ -e "$soma_venv" ]]; then
      /bin/mv "$soma_venv" "$soma_l05_backup"
    fi
    if /bin/mv "$soma_l05_stage" "$soma_venv"; then
      soma_l05_stage=''
      if [[ -d "$soma_l05_backup" && "${soma_l05_backup:h}" == "$soma_l05_parent" ]]; then
        /bin/rm -rf -- "$soma_l05_backup"
      fi
    else
      if [[ -d "$soma_l05_backup" && ! -e "$soma_venv" ]]; then
        /bin/mv "$soma_l05_backup" "$soma_venv"
      fi
      print -u2 -r -- 'could not activate the staged L0.5 environment'
      exit 2
    fi
    print -r -- "Installed the L0.5 Python environment at $soma_venv"
  fi
fi

"$soma_root/scripts/soma-doctor.zsh" --build
print -r -- 'Bootstrap complete. Configure Ollama/Codex and run `scripts/soma-doctor.zsh --runtime` before installation.'
