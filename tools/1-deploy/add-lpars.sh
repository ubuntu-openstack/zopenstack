#!/bin/bash

SCRIPT_DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
# Use edge until this fix gets available in a release
# https://github.com/lxc/lxd/issues/10231
LXD_CHANNEL="latest/edge"

readarray LPARS < ./lpars
if [[ $LPARS == *"EDIT"* ]] 
        then echo ./lpars must be modified to match your environment
                echo It should only contain a space separate list of lpar IP addresses, e.g.
                echo 10.0.0.1 10.0.0.2 10.0.0.3 10.0.0.4 10.0.0.5
        exit 1
fi
SNAPSHOT_LV_PATH='/dev/system/snap-root'

if [ "$1" == "" ] 
        then waitRetry=60
else
        waitRetry=$1
fi

if [ "$2" == "" ] 
        then printf "Checking only - not adding LPARS. Syntax: $0 <sleeptime> ADD to add LPARs\n\n"
fi
 
printf "`date` : Waiting for SSH on all LPARS before proceeding...\n\n"
for lpar in ${LPARS[@]}
        do ssh-keygen -f "$HOME/.ssh/known_hosts" -R $lpar >/dev/null
done
for lpar in ${LPARS[@]}
        do printf "Waiting for $lpar"
        until `ssh ubuntu@${lpar} -o 'StrictHostKeyChecking=no' -o BatchMode=yes true 2>/dev/null` ; do printf "." ; sleep $waitRetry ; done
        printf "\rLPAR $lpar READY. `date`\n"
done
printf "\n\n`date` : Checking for existing lvm root snapshot...\n\n"
for lpar in ${LPARS[@]}
        do printf "Checking $lpar"
        ssh ubuntu@${lpar} -o BatchMode=yes -o StrictHostKeyChecking=no "[[ -L ${SNAPSHOT_LV_PATH} ]]"
        if [ ! $? -eq 0 ] 
                then printf "\rSNAPSHOT NOT OK - Check lv ${lpar}:${SNAPSHOT_LV_PATH}\n"
        else
                printf "\rSNAPSHOT OK $lpar\n"
        fi
done

if [ "$2" == "ADD" ]; then
  for lpar in ${LPARS[@]}; do
    LPAR_IP=${lpar}
    if ! ssh ubuntu@${lpar} "sudo lxc storage info default"; then
        scp ${SCRIPT_DIR}/lxd-config.yaml ubuntu@${lpar}:/tmp/lxd-config.yaml
        ssh ubuntu@${lpar} "sudo snap install --channel ${LXD_CHANNEL} lxd && sudo adduser ubuntu lxd && sudo mkdir -p /mnt/swift/lxd/storage-pools/default"
        ssh ubuntu@${lpar} "cat /tmp/lxd-config.yaml | sudo lxd init --preseed"
    fi
    juju add-machine ssh:ubuntu@${lpar}
  done
fi

juju set-model-constraints arch=s390x
juju sync-agent-binaries

MACHINES=$(juju machines --format json | jq -r '.machines|keys| @tsv' | sed 's/\t/,/g')
SERIES="$(ssh ubuntu@$LPAR_IP -- lsb_release -c -s)"
juju deploy --series $SERIES -n 5 --to $MACHINES --force ch:ubuntu keep
