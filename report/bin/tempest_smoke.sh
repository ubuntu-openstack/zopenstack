#!/usr/bin/env bash

set -xe

cd ../tools/2-configure/tempest/
env https_proxy="http://squid.internal:3128" tox -e smoke
