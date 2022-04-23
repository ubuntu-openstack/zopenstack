#!/bin/bash -eux

readarray LPARS < ./lpars
for LPAR in ${LPARS[@]}; do
  ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "${LPAR}"
  ssh-keyscan -t rsa -H ${LPAR} >> $HOME/.ssh/known_hosts
  # upgrade from focal to jammy needs `-d` until jammy is GA.
  if [ "x$(ssh ubuntu@${LPAR} -- lsb_release -c -s)" != "xjammy" ]; then
    if (( $(distro-info --series=jammy --days) > 0 )); then
      EXTRA_OPTS="-d"
    else
      EXTRA_OPTS=""
    fi
    ssh ubuntu@${LPAR} "sudo  do-release-upgrade $EXTRA_OPTS -f DistUpgradeViewNonInteractive"
  fi
done
