#!/usr/bin/env bash

set -xe

cd ../tools/2-configure/tempest/
tox -e smoke
