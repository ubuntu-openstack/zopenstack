#!/usr/bin/env bash

set -xe

juju exec -u ceph-mon/leader -- sudo ceph osd lspools
juju exec -u ceph-mon/leader -- sudo ceph osd df
juju exec -u ceph-mon/leader -- sudo rados -p cinder-ceph ls
juju exec -u ceph-mon/leader -- sudo rados -p glance ls
