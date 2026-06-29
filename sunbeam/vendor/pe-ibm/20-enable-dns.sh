#!/bin/sh

run_node_cmd 1 sudo k8s status
run_node_cmd 1 sudo k8s enable dns

sleep 10
run_node_cmd 1 sudo k8s kubectl get pod -A -owide

# Fix source of coredns images
run_node_cmd 1 sudo k8s  kubectl set image -n kube-system deployment/coredns coredns=coredns/coredns:1.12.1
run_node_cmd 1 sudo k8s kubectl get pod -A -owide

sleep 10
run_node_cmd 1 sudo k8s kubectl get pod -A -owide
