#!/bin/zsh
set -eu

soma_script_dir=${0:A:h}
soma_root=${soma_script_dir:h}
soma_label=com.soma.reactive-l0
soma_domain="gui/$(id -u)"
soma_target="$soma_domain/$soma_label"
soma_plist="$HOME/Library/LaunchAgents/$soma_label.plist"

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
  /bin/launchctl bootstrap "$soma_domain" "$soma_plist"
  print -r -- 'SOMA started.'
}

function soma_stop() {
  if ! soma_loaded; then
    print -r -- 'SOMA is already stopped.'
    return
  fi
  /bin/launchctl bootout "$soma_domain" "$soma_plist"
  print -r -- 'SOMA stopped.'
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
    if soma_loaded; then
      /bin/launchctl kickstart -k "$soma_target"
      print -r -- 'SOMA restarted.'
    else
      soma_start
    fi
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
