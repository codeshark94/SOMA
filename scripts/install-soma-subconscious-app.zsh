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
soma_subconscious_resources="$soma_build_root/SOMA_SOMASubconscious.bundle"
soma_vad_resources="$soma_build_root/SOMA_SOMAVADModel.bundle"
soma_app_root=${SOMA_APP_ROOT:-"$HOME/Library/Application Support/SOMA/Applications/SOMA Subconscious.app"}
soma_app_binary="$soma_app_root/Contents/MacOS/soma-subconscious"
soma_codex_bridge="$soma_app_root/Contents/Helpers/soma-codex-bridge"
soma_live_voice="$soma_app_root/Contents/Helpers/soma-live-voice"
soma_menu_bar="$soma_app_root/Contents/MacOS/soma-menu-bar"
soma_embodiment="$soma_app_root/Contents/Helpers/soma-embodiment"
soma_codesign_identity=${SOMA_CODESIGN_IDENTITY:-'SOMA Local Persistent Code Signing'}
soma_launch_agents="$HOME/Library/LaunchAgents"
soma_menu_bar_plist="$soma_launch_agents/com.soma.menu-bar.plist"
soma_reactive_plist="$soma_launch_agents/com.soma.reactive-l0.plist"

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
for soma_resource_bundle in "$soma_subconscious_resources" "$soma_vad_resources"; do
  if [[ ! -d "$soma_resource_bundle" ]]; then
    print -u2 "missing SOMA resource bundle: $soma_resource_bundle"
    exit 2
  fi
done

mkdir -p "$soma_app_root/Contents/MacOS" "$soma_app_root/Contents/Helpers"
/usr/bin/ditto "$soma_root/Sources/SOMASubconscious/Info.plist" "$soma_app_root/Contents/Info.plist"
/usr/bin/ditto "$soma_source_binary" "$soma_app_binary"
/usr/bin/ditto "$soma_codex_bridge_source" "$soma_codex_bridge"
/usr/bin/ditto "$soma_live_voice_source" "$soma_live_voice"
/usr/bin/ditto "$soma_menu_bar_source" "$soma_menu_bar"
/usr/bin/ditto "$soma_embodiment_source" "$soma_embodiment"
# SwiftPM's generated accessors retain the matching soma-live build paths.
# Remove resources from legacy root-level staging because a valid macOS app
# may contain sealed payload only under Contents.
/bin/rm -rf \
  "$soma_app_root/SOMA_SOMASubconscious.bundle" \
  "$soma_app_root/SOMA_SOMAVADModel.bundle"
chmod 755 "$soma_app_binary"
chmod 755 "$soma_codex_bridge"
chmod 755 "$soma_live_voice"
chmod 755 "$soma_menu_bar"
chmod 755 "$soma_embodiment"

if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq "$soma_codesign_identity"; then
  soma_codesign_identity='-'
fi
/usr/bin/codesign --force --deep --sign "$soma_codesign_identity" \
  --identifier com.soma.subconscious --timestamp=none "$soma_app_root"
/usr/bin/codesign --verify --deep --strict --verbose=0 "$soma_app_root"

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
print -r -- "$soma_app_binary"
