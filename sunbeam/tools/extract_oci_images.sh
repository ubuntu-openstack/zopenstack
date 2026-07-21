#!/usr/bin/env bash
# Extract OCI image references from one or more YAML/Jinja files.
# Usage: extract_oci_images.sh <file> [<file>...]
# Prints unique image refs (one per line) to stdout. Strips Jinja braces.

set -euo pipefail

if (( $# == 0 )); then
    echo "usage: $0 <file> [<file>...]" >&2
    exit 2
fi

for f in "$@"; do
    [[ -r "$f" ]] || { echo "skipping unreadable: $f" >&2; continue; }
    # Match common registry prefixes and a tag.
    grep -ohE '(ghcr\.io|docker\.io|quay\.io|registry\.k8s\.io)/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+' "$f" \
        || true
    # Also catch `ubuntu/<name>:tag` (Docker Hub library namespace).
    grep -ohE '\b(ubuntu)/[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+' "$f" \
        || true
done | sort -u
