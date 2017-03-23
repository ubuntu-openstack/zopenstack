#!/bin/bash

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
        do ssh-keygen -f "/var/lib/jenkins/.ssh/known_hosts" -R $lpar >/dev/null
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
if [ "$2" == "ADD" ] 
        then for lpar in ${LPARS[@]}
                do juju add-machine ssh:ubuntu@${lpar}
        done
fi
