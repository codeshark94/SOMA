#!/bin/zsh
set -u

soma_root=${0:A:h}
cd "$soma_root" || exit 1

print -r -- 'SOMA full local installation'
print -r -- 'This installs host dependencies, pinned models, signed apps, and enables supported camera motion.'
print -r -- 'OBSBOT Center is not required and must be closed if it is running.'
print -r -- 'macOS may still request account login and Camera, Microphone, Speech Recognition, or Accessibility permission.'
print -r -- ''

"$soma_root/scripts/setup-soma.zsh" --full
soma_status=$?

if (( soma_status == 0 )); then
  print -r -- ''
  print -r -- 'SOMA installation completed successfully.'
else
  print -u2 -r -- ''
  print -u2 -r -- "SOMA installation stopped with status $soma_status. Resolve the reported prerequisite and run this installer again."
fi

if [[ -t 0 ]]; then
  print -n -r -- 'Press Return to close this window.'
  read -r
fi

exit $soma_status
