#!/usr/bin/env bash

set -x

ip_addr="$(openstack floating ip create ext_net | grep floating_ip_address | awk '{print $4}')"
ssh-keygen -f ~/.ssh/known_hosts -R $ip_addr
openstack server add floating ip my-bionic-s390x $ip_addr
sleep 90
ssh ubuntu@$ip_addr -i ~/.ssh/id_rsa -oStrictHostKeyChecking=accept-new echo SSH works
openstack server remove floating ip my-bionic-s390x $ip_addr
