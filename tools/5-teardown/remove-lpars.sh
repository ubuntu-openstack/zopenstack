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
        then waitRetry=10
else
        waitRetry=$1
fi

printf "`date` : Waiting for SSH on all LPARS before proceeding...\n\n"
for lpar in ${LPARS[@]}
        do printf "Waiting for $lpar"
        until `ssh ubuntu@${lpar} -o 'StrictHostKeyChecking=no' -o BatchMode=yes true 2>/dev/null` ; do printf "." ; sleep $waitRetry ; done
        printf "\r`date` :: LPAR $lpar READY.\n"
done
printf "\nCleaning ceph on:\n"
for lpar in ${LPARS[@]}
        do printf "$lpar "
                ssh $lpar "sudo rm -rf /mnt/ceph/*"
                printf "CLEAN\n"
done

printf "\n`date` : Restoring root snapshots...\n\n"
for lpar in ${LPARS[@]}
        do printf "\rRestoring $lpar\n"
        ssh $lpar "touch ~/check_restore && sudo lvconvert --merge ${SNAPSHOT_LV_PATH} && sudo reboot" 2>/dev/null
        if [ $? -eq 2 ] 
                then printf "\rRESTORE FAILED - CHECK LOGS: $lpar\n"
        else
                printf "\rRESTORE OK - REBOOTING $lpar\n\n"
        fi
done
printf "\n`date` : Sleeping 60 seconds to allow for shutdown...\n\n"
sleep 60 
printf "`date` : Waiting for LPARS to restore their snapshots...\n\n"

for lpar in ${LPARS[@]}
        do printf "`date` :: Waiting for restore to complete on: $lpar\n"
        until ssh -o 'StrictHostKeyChecking=no' -o BatchMode=yes $lpar "until ! bash -c \"/usr/bin/sudo /sbin/lvs -va|/bin/grep '\[snap-root\]'\" ; do printf "Restore in progress - watch % of [snap-root]" ; sleep 10 ; done " 2>/dev/null ; do if [ $? -eq 0 ] ; then printf "\nSnapshot restore complete\n" ; fi ; done
        printf "`date` : LPAR SNAPSHOT RESTORE: $lpar READY\n\n"
done

for lpar in ${LPARS[@]}
        do printf "Rebooting $lpar to finalize snapshot recreation...\n\n"
        ssh $lpar "sudo reboot" 2>/dev/null
done

for lpar in ${LPARS[@]}
        do printf "Waiting for $lpar to reboot"
        until `ssh ubuntu@${lpar} -o 'StrictHostKeyChecking=no' -o BatchMode=yes true 2>/dev/null` ; do printf "." ; sleep $waitRetry ; done
        printf "\r`date` :: LPAR $lpar READY.\n"
done

printf "\n\n`date` : Checking restore state...\n\n"
for lpar in ${LPARS[@]}
        do printf "Checking $lpar"
        ssh $lpar "[[ -L ${SNAPSHOT_LV_PATH} ]]"
        if [ ! $? -eq 0 ]
                then printf "\nRESTORE WARNING - SNAPSHOT NOT RECREATED. ${lpar} lvs -av output:\n"
                ssh -o 'StrictHostKeyChecking=no' -o BatchMode=yes $lpar "sudo lvs -av;sudo systemctl status mk-lvm-snapshot.service" 2>/dev/null
        else
                printf "\nSNAPSHOT RECREATED (${SNAPSHOT_LV_PATH})"
        fi
        ssh $lpar "[[ ! -f ~/check_restore ]]"
        if [ $? -eq 0 ] 
                then printf "\nRESTORE FAILED - ~/check_restore still exists on: $lpar\n"
        else
                printf "\nRESTORED SNAPSHOT, FS CLEAN\n"
        fi
printf "\n"
done

