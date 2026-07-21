#!/bin/bash -ex

bundles=$(find ./bundles -name "*.yaml")

for bundle in $bundles; do
    echo "Validating $bundle"
    juju-deployer -c $bundle -d -b
done


