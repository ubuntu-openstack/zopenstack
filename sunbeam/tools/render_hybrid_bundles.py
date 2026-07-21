#!/usr/bin/env python3
"""Render s390x bundles using local charms only where needed."""

from __future__ import annotations

import argparse
from pathlib import Path

import yaml


RABBITMQ_IMAGE = "ghcr.io/canonical/rabbitmq:3.12.1-24.04_edge"


def load_bundle(path: Path) -> list[dict]:
    documents = list(yaml.safe_load_all(path.read_text()))
    if not documents or not isinstance(documents[0], dict):
        raise SystemExit(f"{path}: invalid bundle")
    return documents


def local_charm(charm_dir: Path, filename: str) -> str | None:
    path = charm_dir / filename
    if not path.is_file() or path.stat().st_size == 0:
        return None
    # Juju resolves local charm paths relative to the generated bundle file,
    # which lives under artifacts/<run-id>, not relative to the caller's cwd.
    return str(path.resolve())


def render_control_plane(source: Path, destination: Path, charm_dir: Path) -> None:
    documents = load_bundle(source)
    apps = documents[0]["applications"]

    # These are the channels that currently carry Noble/s390x-compatible
    # revisions. They differ from the generally published bundle defaults.
    apps["tls-operator"]["channel"] = "1/edge"
    apps["tls-operator"]["base"] = "ubuntu@24.04"
    apps["traefik"]["channel"] = "latest/edge"
    apps["traefik"]["base"] = "ubuntu@26.04"

    rabbitmq = local_charm(charm_dir, "rabbitmq-k8s_s390x.charm")
    if rabbitmq:
        app = apps["rabbitmq"]
        app["charm"] = rabbitmq
        app.pop("channel", None)
        app["base"] = "ubuntu@24.04"
        app["resources"] = {"rabbitmq-image": RABBITMQ_IMAGE}

    destination.write_text(yaml.safe_dump_all(documents, sort_keys=False))


def render_machine(source: Path, destination: Path, charm_dir: Path) -> None:
    documents = load_bundle(source)
    apps = documents[0]["applications"]

    overrides = {
        "sunbeam-machine": "sunbeam-machine_s390x.charm",
        "hypervisor": "openstack-hypervisor_s390x.charm",
        "cinder-volume": "cinder-volume_s390x.charm",
        "microceph": "microceph_s390x.charm",
        "cinder-microceph": "cinder-volume-ceph_s390x.charm",
    }
    for application, filename in overrides.items():
        charm = local_charm(charm_dir, filename)
        if charm:
            apps[application]["charm"] = charm
            apps[application].pop("channel", None)

    destination.write_text(yaml.safe_dump_all(documents, sort_keys=False))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    repo = args.repo.resolve()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    charm_dir = repo / "charms"

    render_control_plane(
        repo / "manifests/control-plane-k8s-s390x.yaml",
        output / "control-plane-k8s-s390x-hybrid.yaml",
        charm_dir,
    )
    render_machine(
        repo / "manifests/machine-lpar-s390x.yaml",
        output / "machine-lpar-s390x-hybrid.yaml",
        charm_dir,
    )


if __name__ == "__main__":
    main()
