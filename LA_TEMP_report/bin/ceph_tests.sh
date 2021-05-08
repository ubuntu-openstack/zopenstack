#!/usr/bin/env bash

set -xe

juju run -u ceph-mon/leader -- sudo ceph osd lspools
juju run -u ceph-mon/leader -- sudo ceph osd df
#LA_TODO juju run -u ceph-mon/leader -- sudo rados -p cinder-ceph ls
#LA_TODO juju run -u ceph-mon/leader -- sudo rados -p glance ls
