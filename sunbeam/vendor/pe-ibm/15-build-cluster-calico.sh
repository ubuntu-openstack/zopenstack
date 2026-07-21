#!/bin/bash

. common.sh

cat <<EOF > /tmp/k8s-bootstrap.yaml
cluster-config:
  network:
    enabled: false
EOF

upload_file_to_node /tmp/k8s-bootstrap.yaml 1 /tmp/
run_node_cmd 1 cat /tmp/k8s-bootstrap.yaml
run_node_cmd 1 sudo k8s bootstrap --file /tmp/k8s-bootstrap.yaml

upload_file_to_node calico.yaml 1 /tmp/
run_node_cmd 1 sudo k8s kubectl apply -f /tmp/calico.yaml

sleep 120

if [ -n "$DEVICE_IP" ] || [ -n "$DEVICE_IP_1" ]; then
  # Running under Testflinger.
  python3 join-cluster.py $DEVICE_IP_1 $DEVICE_IP_2 $DEVICE_IP_3
else
  # Running under LXD.
  python3 join-cluster.py k8svm1 k8svm2 k8svm3
fi

# Horrible hack. Do we really need this?
sleep 300

run_cmd_all_nodes sudo k8s kubectl get node -owide
run_cmd_all_nodes sudo k8s kubectl get pod -A -owide
