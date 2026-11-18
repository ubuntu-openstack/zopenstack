#!/usr/bin/env bash
# Backwards-compatible wrapper for the CSI sidecar step.
# Prefer: tools/sideload_s390x_artifacts.sh csi <user@host>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/sideload_s390x_artifacts.sh" csi "$@"
