#!/bin/bash

. common.sh

upload_file_to_node minimal-nginx-v2-no-storage.yaml 1 /tmp/

run_node_cmd 1 sudo k8s kubectl apply -f  /tmp/minimal-nginx-v2-no-storage.yaml


# TODO: check the output to break the wait timer once it's running
for I in `seq 1 6`; do
    sleep 15
    run_node_cmd 1 sudo k8s kubectl get pod -owide
done
