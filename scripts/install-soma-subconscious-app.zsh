#!/bin/zsh
set -eu

soma_script_dir=${0:A:h}
soma_root=${SOMA_ROOT:-${soma_script_dir:h}}
soma_build_root="$soma_root/.build/soma-live/arm64-apple-macosx/debug"
soma_source_binary="$soma_build_root/soma-subconscious"
soma_codex_bridge_source="$soma_build_root/soma-codex-bridge"
soma_live_voice_source="$soma_build_root/soma-live-voice"
soma_menu_bar_source="$soma_build_root/soma-menu-bar"
soma_embodiment_source="$soma_build_root/soma-embodiment"
soma_child_guardian_source="$soma_build_root/soma-child-guardian"
soma_subconscious_resources="$soma_build_root/SOMA_SOMASubconscious.bundle"
soma_vad_resources="$soma_build_root/SOMA_SOMAVADModel.bundle"
soma_menu_bar_resources="$soma_build_root/SOMA_SOMAMenuBar.bundle"
soma_app_icon="$soma_root/assets/branding/SOMA.icns"
soma_native_source="$soma_root/Sources/SOMANativeTracking"
soma_native_build_root="$soma_root/.build/soma-live/native"
soma_native_binary="$soma_native_build_root/soma-native-track"
soma_native_probe="$soma_native_build_root/soma-obsbot-probe"
soma_cmake=${SOMA_CMAKE:-}
soma_tool_path='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'
soma_app_root=${SOMA_APP_ROOT:-"$HOME/Library/Application Support/SOMA/Applications/SOMA Subconscious.app"}
soma_app_binary="$soma_app_root/Contents/MacOS/soma-subconscious"
soma_codex_bridge="$soma_app_root/Contents/Helpers/soma-codex-bridge"
soma_live_voice="$soma_app_root/Contents/Helpers/soma-live-voice"
soma_menu_bar="$soma_app_root/Contents/MacOS/soma-menu-bar"
soma_embodiment="$soma_app_root/Contents/Helpers/soma-embodiment"
soma_child_guardian="$soma_app_root/Contents/Helpers/soma-child-guardian"
soma_native_helper="$soma_app_root/Contents/Helpers/soma-native-track"
soma_device_probe="$soma_app_root/Contents/Helpers/soma-obsbot-probe"
soma_app_parent=${soma_app_root:h}
soma_install_stage=''
soma_install_backup=''
soma_install_committed=0
soma_lock="$soma_root/config/soma-dependencies.env"
[[ -f "$soma_lock" ]] || { print -u2 -r -- "missing dependency lock: $soma_lock"; exit 2; }
source "$soma_lock"
soma_codesign_identity=${SOMA_CODESIGN_IDENTITY:-$SOMA_CODESIGN_IDENTITY_NAME}
soma_launch_agents="$HOME/Library/LaunchAgents"
soma_menu_bar_plist="$soma_launch_agents/com.soma.menu-bar.plist"
soma_reactive_plist="$soma_launch_agents/com.soma.reactive-l0.plist"

function soma_cleanup_install_staging() {
  if [[ -n "$soma_install_stage" \
        && -d "$soma_install_stage" \
        && "${soma_install_stage:h}" == "$soma_app_parent" \
        && "${soma_install_stage:t}" == .soma-install.* ]]; then
    /bin/rm -rf -- "$soma_install_stage"
  fi
  if [[ -n "$soma_install_backup" \
        && -e "$soma_install_backup" \
        && "${soma_install_backup:h}" == "$soma_app_parent" \
        && "${soma_install_backup:t}" == .soma-app-backup.* ]]; then
    if (( soma_install_committed )); then
      /bin/rm -rf -- "$soma_install_backup"
    else
      if [[ -e "$soma_app_root" && "${soma_app_root:h}" == "$soma_app_parent" ]]; then
        /bin/rm -rf -- "$soma_app_root"
      fi
      /bin/mv "$soma_install_backup" "$soma_app_root"
    fi
  fi
}
trap soma_cleanup_install_staging EXIT

if [[ -z "$soma_cmake" ]]; then
  soma_cmake=$(PATH="$soma_tool_path" command -v cmake 2>/dev/null || true)
fi
if [[ -z "$soma_cmake" || ! -x "$soma_cmake" ]]; then
  print -u2 'missing CMake; set SOMA_CMAKE to the cmake executable path'
  exit 2
fi

"$soma_root/scripts/soma-doctor.zsh" --runtime

# Installation is a deployment boundary: rebuild the shared staging directory
# before copying so an earlier local artifact cannot silently replace newer
# source changes in the signed app.
/usr/bin/env swift build --package-path "$soma_root" --scratch-path "$soma_root/.build/soma-live"
"$soma_cmake" \
  -S "$soma_native_source" \
  -B "$soma_native_build_root"
"$soma_cmake" --build "$soma_native_build_root" --parallel

if [[ ! -x "$soma_source_binary" ]]; then
  print -u2 "missing SOMA source binary: $soma_source_binary"
  exit 2
fi
if [[ ! -x "$soma_codex_bridge_source" ]]; then
  print -u2 "missing SOMA Codex bridge: $soma_codex_bridge_source"
  exit 2
fi
if [[ ! -x "$soma_live_voice_source" ]]; then
  print -u2 "missing SOMA Live Voice helper: $soma_live_voice_source"
  exit 2
fi
if [[ ! -x "$soma_menu_bar_source" ]]; then
  print -u2 "missing SOMA menu bar source: $soma_menu_bar_source"
  exit 2
fi
if [[ ! -x "$soma_embodiment_source" ]]; then
    print -u2 "missing SOMA embodiment MCP: $soma_embodiment_source"
    exit 2
fi
if [[ ! -x "$soma_child_guardian_source" ]]; then
    print -u2 "missing SOMA child guardian: $soma_child_guardian_source"
    exit 2
fi
if [[ ! -x "$soma_native_binary" ]]; then
    print -u2 "missing SOMA native gimbal/audio helper: $soma_native_binary"
    exit 2
fi
if [[ ! -x "$soma_native_probe" ]]; then
    print -u2 "missing SOMA native device probe: $soma_native_probe"
    exit 2
fi
for soma_resource_bundle in "$soma_subconscious_resources" "$soma_vad_resources" "$soma_menu_bar_resources"; do
  if [[ ! -d "$soma_resource_bundle" ]]; then
    print -u2 "missing SOMA resource bundle: $soma_resource_bundle"
    exit 2
  fi
done
if [[ ! -f "$soma_app_icon" ]]; then
  print -u2 "missing SOMA application icon: $soma_app_icon"
  exit 2
fi

mkdir -p "$soma_app_parent"
soma_install_stage=$(mktemp -d "$soma_app_parent/.soma-install.XXXXXX")
soma_stage_app="$soma_install_stage/${soma_app_root:t}"
soma_stage_app_binary="$soma_stage_app/Contents/MacOS/soma-subconscious"
soma_stage_codex_bridge="$soma_stage_app/Contents/Helpers/soma-codex-bridge"
soma_stage_live_voice="$soma_stage_app/Contents/Helpers/soma-live-voice"
soma_stage_menu_bar="$soma_stage_app/Contents/MacOS/soma-menu-bar"
soma_stage_embodiment="$soma_stage_app/Contents/Helpers/soma-embodiment"
soma_stage_child_guardian="$soma_stage_app/Contents/Helpers/soma-child-guardian"
soma_stage_native_helper="$soma_stage_app/Contents/Helpers/soma-native-track"
soma_stage_device_probe="$soma_stage_app/Contents/Helpers/soma-obsbot-probe"
mkdir -p \
  "$soma_stage_app/Contents/MacOS" \
  "$soma_stage_app/Contents/Helpers" \
  "$soma_stage_app/Contents/Resources"
/usr/bin/ditto "$soma_root/Sources/SOMASubconscious/Info.plist" "$soma_stage_app/Contents/Info.plist"
/usr/bin/ditto "$soma_source_binary" "$soma_stage_app_binary"
/usr/bin/ditto "$soma_codex_bridge_source" "$soma_stage_codex_bridge"
/usr/bin/ditto "$soma_live_voice_source" "$soma_stage_live_voice"
/usr/bin/ditto "$soma_menu_bar_source" "$soma_stage_menu_bar"
/usr/bin/ditto "$soma_embodiment_source" "$soma_stage_embodiment"
/usr/bin/ditto "$soma_child_guardian_source" "$soma_stage_child_guardian"
/usr/bin/ditto "$soma_native_binary" "$soma_stage_native_helper"
/usr/bin/ditto "$soma_native_probe" "$soma_stage_device_probe"
/usr/bin/ditto \
  "$soma_subconscious_resources" \
  "$soma_stage_app/Contents/Resources/${soma_subconscious_resources:t}"
/usr/bin/ditto \
  "$soma_vad_resources" \
  "$soma_stage_app/Contents/Resources/${soma_vad_resources:t}"
/usr/bin/ditto \
  "$soma_menu_bar_resources" \
  "$soma_stage_app/Contents/Resources/${soma_menu_bar_resources:t}"
/usr/bin/ditto "$soma_app_icon" "$soma_stage_app/Contents/Resources/SOMA.icns"
if [[ ! -f "$soma_stage_app/Contents/Resources/${soma_menu_bar_resources:t}/SOMALogoMark.png" \
      || ! -f "$soma_stage_app/Contents/Resources/SOMA.icns" ]]; then
  print -u2 'staged SOMA application is missing packaged branding resources'
  exit 2
fi
if /usr/bin/otool -L "$soma_stage_native_helper" "$soma_stage_device_probe" \
    | /usr/bin/grep -Fq 'libdev'; then
  print -u2 'native OBSBOT helper unexpectedly links a proprietary runtime'
  exit 2
fi
chmod 755 "$soma_stage_app_binary"
chmod 755 "$soma_stage_codex_bridge"
chmod 755 "$soma_stage_live_voice"
chmod 755 "$soma_stage_menu_bar"
chmod 755 "$soma_stage_embodiment"
chmod 755 "$soma_stage_child_guardian"
chmod 755 "$soma_stage_native_helper"
chmod 755 "$soma_stage_device_probe"

if ! /usr/bin/codesign --dryrun --force --sign "$soma_codesign_identity" \
    --timestamp=none "$soma_source_binary" >/dev/null 2>&1; then
  print -u2 -r -- "missing usable persistent code-signing identity: $soma_codesign_identity"
  exit 2
fi
/usr/bin/codesign --force --deep --sign "$soma_codesign_identity" \
  --identifier com.soma.subconscious --timestamp=none "$soma_stage_app"
/usr/bin/codesign --verify --deep --strict --verbose=0 "$soma_stage_app"

soma_install_backup="$soma_app_parent/.soma-app-backup.$$"
if [[ -e "$soma_install_backup" ]]; then
  print -u2 -r -- "unexpected application backup path: $soma_install_backup"
  exit 2
fi
if [[ -e "$soma_app_root" ]]; then
  /bin/mv "$soma_app_root" "$soma_install_backup"
fi
if ! /bin/mv "$soma_stage_app" "$soma_app_root"; then
  if [[ -e "$soma_install_backup" && ! -e "$soma_app_root" ]]; then
    /bin/mv "$soma_install_backup" "$soma_app_root"
  fi
  print -u2 'could not activate the staged SOMA application'
  exit 2
fi
/usr/bin/codesign --verify --deep --strict --verbose=0 "$soma_app_root"
if ! /usr/bin/cmp -s \
      "$soma_root/Sources/SOMAMenuBar/Resources/SOMALogoMark.png" \
      "$soma_app_root/Contents/Resources/${soma_menu_bar_resources:t}/SOMALogoMark.png" \
    || ! /usr/bin/cmp -s \
      "$soma_app_icon" \
      "$soma_app_root/Contents/Resources/SOMA.icns"; then
  print -u2 'installed SOMA branding resources differ from the staged build'
  exit 2
fi
if find "$soma_app_root" -type f \( -name 'libdev.dylib' -o -name 'soma-open-obsbot-*' \) \
    -print -quit | /usr/bin/grep -q .; then
  print -u2 'the installed application contains a retired OBSBOT runtime'
  exit 2
fi
/bin/rm -rf -- "$soma_install_stage"
soma_install_stage=''

mkdir -p "$soma_launch_agents"
function soma_escape_sed_replacement() {
  print -r -- "$1" | /usr/bin/sed 's/[\\\\&|]/\\\\&/g'
}

function soma_render_launch_agent() {
  local soma_template="$1"
  local soma_destination="$2"
  local soma_root_escaped
  local soma_app_root_escaped
  soma_root_escaped=$(soma_escape_sed_replacement "$soma_root")
  soma_app_root_escaped=$(soma_escape_sed_replacement "$soma_app_root")
  /usr/bin/sed \
    -e "s|@SOMA_ROOT@|$soma_root_escaped|g" \
    -e "s|@SOMA_APP_ROOT@|$soma_app_root_escaped|g" \
    "$soma_template" > "$soma_destination"
  /usr/bin/plutil -lint "$soma_destination" >/dev/null
}

soma_render_launch_agent \
  "$soma_root/LaunchAgents/com.soma.menu-bar.plist" \
  "$soma_menu_bar_plist"
soma_render_launch_agent \
  "$soma_root/LaunchAgents/com.soma.reactive-l0.plist" \
  "$soma_reactive_plist"
/bin/launchctl bootout "gui/$(id -u)" "$soma_menu_bar_plist" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$(id -u)" "$soma_menu_bar_plist"
/bin/launchctl enable "gui/$(id -u)/com.soma.reactive-l0" >/dev/null 2>&1 || true
if /bin/launchctl print "gui/$(id -u)/com.soma.reactive-l0" >/dev/null 2>&1; then
  "$soma_root/scripts/soma.zsh" restart
else
  /bin/launchctl bootstrap "gui/$(id -u)" "$soma_reactive_plist"
fi
soma_install_committed=1
soma_cleanup_install_staging
soma_install_backup=''
print -r -- "$soma_app_binary"
