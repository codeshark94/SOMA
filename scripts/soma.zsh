#!/bin/zsh
set -eu

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_label=com.soma.reactive-l0
soma_domain="gui/$(id -u)"
soma_target="$soma_domain/$soma_label"
soma_plist="$HOME/Library/LaunchAgents/$soma_label.plist"
soma_app_root="${SOMA_APP_ROOT:-$HOME/Library/Application Support/SOMA/Applications/SOMA Subconscious.app}"
soma_runtime_control="$soma_app_root/Contents/Helpers/soma-embodiment"
soma_runtime_socket="$soma_root/artifacts/subconscious/runtime/ipc/embodiment-shadow.sock"

function soma_loaded() {
  local soma_status
  soma_status=$(/bin/launchctl print "$soma_target" 2>&1 || true)
  [[ "$soma_status" == *"$soma_target = {"* ]]
}

function soma_start() {
  if soma_loaded; then
    print -r -- 'SOMA is already running.'
    return
  fi
  if [[ ! -f "$soma_plist" ]]; then
    print -u2 -r -- "SOMA is not installed. Run $soma_root/scripts/install-soma-subconscious-app.zsh first."
    return 2
  fi
  /bin/launchctl enable "$soma_target" >/dev/null 2>&1 || true
  /bin/launchctl bootstrap "$soma_domain" "$soma_plist"
  print -r -- 'SOMA started.'
}

function soma_quiesce_runtime() {
  local graceful_shutdown=false
  if [[ -x "$soma_runtime_control" && -S "$soma_runtime_socket" ]]; then
    # The endpoint becomes available after the perception runtime has bound
    # its local socket. A launchd restart can make the socket pathname visible
    # just before accept() is ready, so retry the same idempotent lifecycle
    # request instead of immediately cutting off the gimbal park sequence.
    for attempt in {1..12}; do
      if "$soma_runtime_control" --runtime-shutdown --socket "$soma_runtime_socket"; then
        graceful_shutdown=true
        break
      fi
      sleep 1
    done
    if [[ "$graceful_shutdown" != true ]]; then
      print -u2 -r -- 'SOMA did not confirm gimbal park and camera sleep; lifecycle transition cancelled.'
      return 1
    fi
  else
    print -u2 -r -- 'SOMA graceful shutdown endpoint is unavailable; lifecycle transition cancelled.'
    return 1
  fi
}

function soma_stop() {
  if ! soma_loaded; then
    print -r -- 'SOMA is already stopped.'
    return
  fi
  # Disable KeepAlive before quiescing so launchd cannot wake a device between
  # the verified sleep acknowledgement and bootout.
  /bin/launchctl disable "$soma_target" >/dev/null 2>&1 || true
  if ! soma_quiesce_runtime; then
    /bin/launchctl enable "$soma_target" >/dev/null 2>&1 || true
    return 1
  fi
  /bin/launchctl bootout "$soma_domain" "$soma_plist"
  print -r -- 'SOMA stopped.'
}

function soma_restart() {
  if ! soma_loaded; then
    soma_start
    return
  fi
  local previous_pid
  previous_pid=$(/bin/launchctl print "$soma_target" 2>/dev/null \
    | /usr/bin/sed -n 's/^[[:space:]]*pid = //p' \
    | /usr/bin/head -n 1)
  soma_quiesce_runtime
  /bin/launchctl kickstart -k "$soma_target"
  local current_pid=''
  for attempt in {1..50}; do
    current_pid=$(/bin/launchctl print "$soma_target" 2>/dev/null \
      | /usr/bin/sed -n 's/^[[:space:]]*pid = //p' \
      | /usr/bin/head -n 1)
    if [[ -n "$current_pid" && "$current_pid" != "$previous_pid" ]]; then
      print -r -- "SOMA restarted after verified park and sleep (pid=$current_pid)."
      return
    fi
    sleep 0.2
  done
  print -u2 -r -- 'SOMA restart did not produce a new runtime process.'
  return 1
}

case "${1:-start}" in
  start)
    (( $# == 0 || $# == 1 )) || { print -u2 -r -- 'Usage: soma [start|stop|restart|status]'; exit 64; }
    soma_start
    ;;
  stop)
    (( $# == 1 )) || { print -u2 -r -- 'Usage: soma [start|stop|restart|status]'; exit 64; }
    soma_stop
    ;;
  restart)
    (( $# == 1 )) || { print -u2 -r -- 'Usage: soma [start|stop|restart|status]'; exit 64; }
    soma_restart
    ;;
  status)
    (( $# == 1 )) || { print -u2 -r -- 'Usage: soma [start|stop|restart|status]'; exit 64; }
    if soma_loaded; then
      print -r -- 'SOMA is running.'
    else
      print -r -- 'SOMA is stopped.'
      exit 3
    fi
    ;;
  *)
    print -u2 -r -- 'Usage: soma [start|stop|restart|status]'
    exit 64
    ;;
esac
