#!/bin/bash -eu
#
# This program does a juju bootstrap with the manual provider

CONTROLLER_IP="$1"

if [ -z "$CONTROLLER_IP" ]; then
  echo "Usage: $0 <controller_ip> [controller_name]"
  exit 1
fi

CLOUD_NAME="manual/ubuntu@${CONTROLLER_IP}"
CONTROLLER_NAME=${2:-juju-controller-s390x}

ssh-keygen -f "$HOME/.ssh/known_hosts" -R "${CONTROLLER_IP}"
ssh-keyscan -t rsa -H ${CONTROLLER_IP} >> $HOME/.ssh/known_hosts
echo "juju bootstrap..."
juju bootstrap \
     ${CLOUD_NAME} ${CONTROLLER_NAME}

# workaround to assign static IP addresses in containers, this is because z13
# doesn't support promiscuos mode on bridges.
juju model-default cloudinit-userdata="$(cat juju-model-config-cloudinit-userdata-lxd.yaml)"
