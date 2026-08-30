#!/bin/zsh
set -euo pipefail

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_lock="$soma_root/config/soma-dependencies.env"
soma_plan_only=0
soma_stage=''

function soma_cleanup() {
  if [[ -n "$soma_stage" \
        && -d "$soma_stage" \
        && "${soma_stage:h}" == /private/tmp \
        && "${soma_stage:t}" == soma-signing.* ]]; then
    /bin/rm -rf -- "$soma_stage"
  fi
}
trap soma_cleanup EXIT

function soma_usage() {
  print -r -- 'Usage: scripts/ensure-soma-signing-identity.zsh [--plan]'
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
source "$soma_lock"
soma_identity=${SOMA_CODESIGN_IDENTITY:-$SOMA_CODESIGN_IDENTITY_NAME}
soma_keychain=${SOMA_CODESIGN_KEYCHAIN:-}

function soma_identity_is_usable() {
  if [[ -n "$soma_keychain" ]]; then
    /usr/bin/security find-identity -v -p codesigning "$soma_keychain" \
      | /usr/bin/grep -Fq \"$soma_identity\"
  else
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/grep -Fq \"$soma_identity\"
  fi
}

if (( soma_plan_only )); then
  print -r -- 'SOMA signing identity plan'
  print -r -- "  identity: $soma_identity"
  print -r -- '  keychain: current user default keychain'
  print -r -- '  action: preserve a usable identity or create a ten-year local self-signed code-signing root'
  exit 0
fi

if soma_identity_is_usable; then
  print -r -- "Code-signing identity is already usable: $soma_identity"
  exit 0
fi

if [[ -z "$soma_keychain" ]]; then
  soma_keychain=$(/usr/bin/security default-keychain -d user | tr -d '"')
fi
[[ -n "$soma_keychain" && -f "$soma_keychain" ]] \
  || { print -u2 -r -- 'Unable to locate the current user default keychain.'; exit 2; }

soma_stage=$(mktemp -d /private/tmp/soma-signing.XXXXXX)
soma_password="$(/usr/bin/uuidgen)$(/usr/bin/uuidgen)"
soma_key="$soma_stage/identity.key"
soma_cert="$soma_stage/identity.pem"
soma_bundle="$soma_stage/identity.p12"

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -subj "/CN=$soma_identity/O=SOMA" \
  -addext 'basicConstraints=critical,CA:TRUE' \
  -addext 'keyUsage=critical,digitalSignature,keyCertSign' \
  -addext 'extendedKeyUsage=codeSigning' \
  -keyout "$soma_key" \
  -out "$soma_cert" >/dev/null 2>&1
/usr/bin/openssl pkcs12 -export \
  -inkey "$soma_key" \
  -in "$soma_cert" \
  -name "$soma_identity" \
  -passout "pass:$soma_password" \
  -out "$soma_bundle"

/usr/bin/security import "$soma_bundle" \
  -k "$soma_keychain" \
  -P "$soma_password" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null
/usr/bin/security add-trusted-cert -r trustRoot -p codeSign \
  -k "$soma_keychain" "$soma_cert"

if ! soma_identity_is_usable; then
  print -u2 -r -- "Created certificate is not a usable code-signing identity: $soma_identity"
  exit 2
fi

print -r -- "Created persistent local code-signing identity: $soma_identity"
