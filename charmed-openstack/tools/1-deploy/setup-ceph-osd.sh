#!/bin/bash -ex

CEPH_OSD_UNITS="$(juju status --format json ceph-osd | jq -r '.applications."ceph-osd".units|keys|@tsv')"

for UNIT in $CEPH_OSD_UNITS; do
  # Sometimes $dev is present but not $partition yet and it will make it show
  # up:
  SERIES=$(juju ssh $UNIT "lsb_release -s -c" | tr -d '\r')

  # find the disk labeled CEPH
  for DEV in /dev/dasd{b..z};do
    if juju ssh $UNIT -- sudo fdasd -i $DEV 2>/dev/null | grep CEPH; then
      DEVICE=$DEV
      break
    fi
  done
  if [ -z "$DEVICE" ]; then
    echo "CEPH device not found"
    exit 1
  fi
  PARTITION="${DEVICE}1"

  if [[ "$SERIES" > "bionic" ]]; then
    juju ssh $UNIT "sudo fdasd -a $DEVICE -l ceph && sudo partprobe"
    juju ssh $UNIT "test -e $PARTITION"
  fi

  # `juju run` runs actions on juju-3.x
  juju run $UNIT zap-disk devices=$PARTITION i-really-mean-it=true
  juju run $UNIT add-disk osd-devices=$PARTITION
done
