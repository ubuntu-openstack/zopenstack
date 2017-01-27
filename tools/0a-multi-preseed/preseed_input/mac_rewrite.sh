#!/bin/bash
#
# Script to rewrite ether headers for macs to get lxc working on z
#
# Andrew McLeod 
#
ebtables -t nat --flush
 
hostmac=`ip addr show encc000|grep ether|awk '{print $2}'`
hostsnat=`ebtables -t nat -L --Lmac2|grep snat`
  
if ! [[ ${hostsnat} == *${hostmac}* ]]
  then 
  ebtables -t nat -A POSTROUTING -o encc000.2893 -j snat --to-src ${hostmac} --snat-arp --snat-target ACCEPT
fi 
   
for ip in `lxc list -c n4|egrep -v 'NAME|--'|awk '{print $4}'|tr -d '|'` ;
  do if [ ! ${ip} == '' ] ; then 
    ping -c 1 ${ip} > /dev/null ; 
    mac=`arp -a |grep ${ip} | awk '{print $4}'` ; 
    if ! [[ $(ebtables -t nat -Ln --Lmac2) == *${mac}* ]]
    then
      ebtables -t nat -A PREROUTING -p IPv4 -i encc000.2893 --ip-dst ${ip} -j dnat --to-dst ${mac} --dnat-target ACCEPT ;
      ebtables -t nat -A PREROUTING -p ARP -i encc000.2893 --arp-ip-dst ${ip} -j dnat --to-dst ${mac} --dnat-target ACCEPT ; 
    fi
  fi
done
