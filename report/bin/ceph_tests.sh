#!/usr/bin/env bash

set -xe

juju run -u ceph-mon/leader -- sudo ceph osd lspools
juju run -u ceph-mon/leader -- sudo ceph osd df
juju run -u ceph-mon/leader -- sudo rados -p cinder-ceph ls
juju run -u ceph-mon/leader -- sudo rados -p glance ls
