#!/bin/bash -e
#
# This program does a juju bootstrap with the manual provider using locally
# built binaries which are searched in ~/git/juju , it's up to the user to
# have them already built for amd64 and s390x running the following commands
# in the juju repo:
#
#   $ make build  # build amd64
#   $ env GOOS=linux GOARCH=s390x make build

CONTROLLER_IP="$1"

if [ -z "$CONTROLLER_IP" ]; then
  echo "Usage: $0 <controller_ip> [controller_name]"
  exit 1
fi

CLOUD_NAME="manual/ubuntu@${CONTROLLER_IP}"
CONTROLLER_NAME=${2:-juju-controller-s390x}
SCRIPT_DIR=$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)
JUJU_REPO_DIR="$HOME/git/juju"
JUJU_BRANCH="2.9"

cd $JUJU_REPO_DIR
git checkout $JUJU_BRANCH
JUJU_VERSION=$(grep "const version" version/version.go | awk '{print $4}' | tr -d '"')
echo "Using juju version $JUJU_VERSION"
if [ ! -d "${JUJU_REPO_DIR}/_build/linux_s390x" ]; then
  echo "build for s390x not found at ${JUJU_REPO_DIR}/_build/linux_s390x"
  exit 1
fi

if [ ! -d "${JUJU_REPO_DIR}/_build/linux_amd64" ]; then
  echo "build for amd64 not found at ${JUJU_REPO_DIR}/_build/linux_amd64"
  exit 1
fi

rm -rf ${SCRIPT_DIR}/simplestreams
mkdir -p ${SCRIPT_DIR}/simplestreams/tools/released/

cd ${JUJU_REPO_DIR}/_build/linux_s390x/bin
echo "Creating tarball: juju-${JUJU_VERSION}-ubuntu-s390x.tgz"
tar czf ${SCRIPT_DIR}/simplestreams/tools/released/juju-${JUJU_VERSION}-ubuntu-s390x.tgz \
    containeragent juju jujuc jujud juju-metadata juju-wait-for pebble
echo "Creating tarball: juju-${JUJU_VERSION}-ubuntu-amd64.tgz"
cd ${JUJU_REPO_DIR}/_build/linux_amd64/bin
tar czf ${SCRIPT_DIR}/simplestreams/tools/released/juju-${JUJU_VERSION}-ubuntu-amd64.tgz \
    containeragent juju jujuc jujud juju-metadata juju-wait-for pebble

echo "Running juju metadata generate-agents..."
juju metadata generate-agents -d ${SCRIPT_DIR}/simplestreams --clean --prevent-fallback


ssh-keygen -f "/home/ubuntu/.ssh/known_hosts" -R "${CONTROLLER_IP}"
ssh-keyscan -t rsa -H ${CONTROLLER_IP} >> $HOME/.ssh/known_hosts
echo "juju bootstrap..."
juju bootstrap --agent-version $JUJU_VERSION --no-gui --metadata-source ${SCRIPT_DIR}/simplestreams ${CLOUD_NAME} ${CONTROLLER_NAME}
echo "juju sync-agent-binaries..."
juju sync-agent-binaries --source $HOME/simplestreams/tools
