#!/usr/bin/env bash

output=''
for application in $(juju status --format json | jq -r '.applications|keys|@tsv'); do
    for config in openstack-origin source; do
        set -x
        origin="$(juju config $application $config 2>/dev/null)"
        exit_code=$?
        set +x
        if [[ "$exit_code" == "0" ]]; then
            output="$output\n$application: $config=$origin"
            break
        fi
    done
done
echo -e $output
