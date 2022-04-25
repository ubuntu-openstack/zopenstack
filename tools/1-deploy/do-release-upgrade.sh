#!/bin/bash -eux

readarray LPARS < ./lpars
for LPAR in ${LPARS[@]}; do
  ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${LPAR}"
  ssh-keyscan -t rsa -H ${LPAR} >> $HOME/.ssh/known_hosts
  # upgrade from focal to jammy needs `-d` until jammy is GA.
  if [ "x$(ssh ubuntu@${LPAR} -- lsb_release -c -s)" != "xjammy" ]; then
    # The -d flag is needed not until the LTS version is released, instead
    # until the first point release of the LTS is released, that milestone is
    # reflected on the meta-release-lts file which is consumed by
    # do-release-upgrade to determine if there is a new version available.
    if ! curl -s "http://changelogs.ubuntu.com/meta-release-lts" | grep -q "Dist: jammy"; then
      EXTRA_OPTS="-d"
    else
      EXTRA_OPTS=""
    fi
    ssh ubuntu@${LPAR} "sudo do-release-upgrade $EXTRA_OPTS -f DistUpgradeViewNonInteractive"
    ssh ubuntu@${LPAR} "sudo reboot" || echo "Rebooting ${LPAR}..."
  fi
done
