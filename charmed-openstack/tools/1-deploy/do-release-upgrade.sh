#!/bin/bash -eux

EXTRA_OPTS=$1

readarray LPARS < ./lpars
for LPAR in ${LPARS[@]}; do
  ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${LPAR}"
  ssh-keyscan -t rsa -H ${LPAR} >> $HOME/.ssh/known_hosts
  ssh ubuntu@${LPAR} "sudo do-release-upgrade $EXTRA_OPTS -f DistUpgradeViewNonInteractive"
  ssh ubuntu@${LPAR} "sudo reboot" || echo "Rebooting ${LPAR}..."
done
