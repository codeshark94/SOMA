#!/bin/zsh
set -eu

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_brand_root="$soma_root/assets/branding"
soma_source="$soma_brand_root/soma-original.png"
soma_menu_resource_root="$soma_root/Sources/SOMAMenuBar/Resources"
soma_mode=${1:---write}
if [[ "$soma_mode" != '--write' && "$soma_mode" != '--check' ]]; then
  print -u2 -r -- 'Usage: scripts/generate-soma-brand-assets.zsh [--write|--check]'
  exit 64
fi
soma_icon_workspace=$(mktemp -d /private/tmp/soma-brand-icon.XXXXXX)
trap '/bin/rm -rf -- "$soma_icon_workspace"' EXIT
soma_iconset="$soma_icon_workspace/SOMA.iconset"
soma_output_root="$soma_brand_root"
if [[ "$soma_mode" == '--check' ]]; then
  soma_output_root="$soma_icon_workspace/generated"
  /bin/mkdir -p "$soma_output_root"
fi

/usr/bin/swift \
  "$soma_root/scripts/generate-soma-brand-assets.swift" \
  "$soma_source" \
  "$soma_output_root"

/bin/mkdir -p "$soma_iconset"
if [[ "$soma_mode" == '--write' ]]; then
  /bin/mkdir -p "$soma_menu_resource_root"
  /usr/bin/ditto \
    "$soma_output_root/soma-mark.png" \
    "$soma_menu_resource_root/SOMALogoMark.png"
fi

typeset -a soma_icon_specs=(
  '16 icon_16x16.png'
  '32 icon_16x16@2x.png'
  '32 icon_32x32.png'
  '64 icon_32x32@2x.png'
  '128 icon_128x128.png'
  '256 icon_128x128@2x.png'
  '256 icon_256x256.png'
  '512 icon_256x256@2x.png'
  '512 icon_512x512.png'
  '1024 icon_512x512@2x.png'
)

for soma_icon_spec in "${soma_icon_specs[@]}"; do
  soma_dimensions=${soma_icon_spec%% *}
  soma_filename=${soma_icon_spec#* }
  /usr/bin/sips \
    --resampleHeightWidth "$soma_dimensions" "$soma_dimensions" \
    "$soma_output_root/soma-app-icon.png" \
    --out "$soma_iconset/$soma_filename" >/dev/null
done

/usr/bin/iconutil \
  --convert icns \
  "$soma_iconset" \
  --output "$soma_output_root/SOMA.icns"

if [[ "$soma_mode" == '--check' ]]; then
  /usr/bin/cmp -s "$soma_output_root/soma-mark.png" "$soma_brand_root/soma-mark.png" \
    && /usr/bin/cmp -s "$soma_output_root/soma-mark.png" "$soma_menu_resource_root/SOMALogoMark.png" \
    && /usr/bin/cmp -s "$soma_output_root/soma-app-icon.png" "$soma_brand_root/soma-app-icon.png" \
    && /usr/bin/cmp -s "$soma_output_root/SOMA.icns" "$soma_brand_root/SOMA.icns"
  exit $?
fi

print -r -- "$soma_output_root/soma-mark.png"
print -r -- "$soma_output_root/soma-app-icon.png"
print -r -- "$soma_output_root/SOMA.icns"
