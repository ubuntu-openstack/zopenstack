#!/usr/bin/env python3
"""Render a Sunbeam bundle for a target OpenStack release and Ubuntu base.

The static bundles pin one release profile. This tool applies per-release
overrides for the core service and machine charms so the same topology can
target another supported release/base.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import yaml

# OpenStack release (and OVN release) channel pins that currently publish
# s390x revisions. Dependency charms keep the channels from the source bundle;
# rabbitmq-k8s still has no s390x charm revision, so hybrid/local mode must
# supply a local RabbitMQ charm and s390x image.
RELEASES = {
    "2026.1": {
        "base": "ubuntu@24.04",
        "core_channel": "2026.1/edge",
        "machine_channel": "2026.1/edge",
        "microceph_channel": "tentacle/edge",
        "microovn_channel": "26.03/edge",
        "ovn_proxy_channel": "2026.1/edge",
        "token_distributor_channel": "v1/stable",
        "snap_channels": {
            "cinder-volume": "2026.1/edge",
            "hypervisor": "2026.1/edge",
            "microceph": "tentacle/edge",
            "openstack-network-agents": "2026.1/edge",
        },
        "base_overrides": {
            "ubuntu@24.04": {
                "preserve_channels": True,
            },
            "ubuntu@26.04": {
                "machine_channel": "2026.2/edge",
                "microceph_channel": "tentacle/edge",
                "ovn_proxy_channel": "2026.2/edge",
                "snap_channels": {
                    "cinder-volume": "2026.2/edge",
                    "hypervisor": "2026.2/edge",
                    "microceph": "tentacle/edge",
                    "openstack-network-agents": "2026.2/edge",
                },
            },
        },
    },
    "2026.2": {
        "base": "ubuntu@26.04",
        "core_channel": "2026.2/edge",
        "machine_channel": "2026.2/edge",
        "microceph_channel": "tentacle/edge",
        "microovn_channel": "26.03/edge",
        "ovn_proxy_channel": "2026.2/edge",
        "token_distributor_channel": "v1/stable",
        "snap_channels": {
            "cinder-volume": "2026.2/edge",
            "hypervisor": "2026.2/edge",
            "microceph": "tentacle/edge",
            "openstack-network-agents": "2026.2/edge",
        },
        "drop_machine_relations": [
            "hypervisor:ovsdb-cms",
        ],
    },
}

ALIASES = {
    "gazpacho": "2026.1",
    "2026.1": "2026.1",
    "hibiscus": "2026.2",
    "2026.2": "2026.2",
}

CORE_APPS = {"keystone", "glance", "placement", "nova", "neutron", "cinder"}
MACHINE_APPS = {
    "sunbeam-machine",
    "cinder-volume",
    "hypervisor",
    "cinder-microceph",
}
OVN_MACHINE_APPS = {
    "microovn": "microovn_channel",
    "sunbeam-ovn-proxy": "ovn_proxy_channel",
    "microcluster-token-distributor": "token_distributor_channel",
}


RELEASE_RE = re.compile(r"^\d{4}\.\d+$")


def resolve_release(value: str) -> str:
    value = value.strip().lower()
    key = ALIASES.get(value, value if RELEASE_RE.match(value) else "")
    if not key:
        raise SystemExit(
            f"unsupported release '{value}'; expected a release such as "
            "2027.1 or one of: " + ", ".join(sorted(ALIASES))
        )
    return key


def release_profile(release: str) -> dict:
    if release in RELEASES:
        return RELEASES[release]
    # Future releases default to <release>/edge for Sunbeam charms and reuse
    # the latest known base and independent publication tracks. Override the
    # base or individual channels when a newer release moves them.
    latest = RELEASES[max(RELEASES)]
    return {
        "base": latest["base"],
        "core_channel": f"{release}/edge",
        "machine_channel": f"{release}/edge",
        "microceph_channel": latest["microceph_channel"],
        "microovn_channel": latest["microovn_channel"],
        "ovn_proxy_channel": f"{release}/edge",
        "token_distributor_channel": latest["token_distributor_channel"],
        "snap_channels": {
            "cinder-volume": f"{release}/edge",
            "hypervisor": f"{release}/edge",
            "microceph": latest["microceph_channel"],
            "openstack-network-agents": f"{release}/edge",
        },
        "drop_machine_relations": latest.get("drop_machine_relations", []),
    }


def load_bundle(path: Path) -> list[dict]:
    documents = list(yaml.safe_load_all(path.read_text(encoding="utf-8")))
    if not documents or not isinstance(documents[0], dict):
        raise SystemExit(f"{path}: invalid bundle")
    return documents


def save_bundle(path: Path, documents: list[dict]) -> None:
    path.write_text(
        yaml.safe_dump_all(documents, sort_keys=False), encoding="utf-8"
    )


def render_control_plane(
    documents: list[dict], release: str, base: str
) -> list[dict]:
    profile = release_profile(release)
    applications = documents[0].get("applications", {})
    for name, app in applications.items():
        if not isinstance(app, dict):
            continue
        if name in CORE_APPS:
            if "channel" in app:
                app["channel"] = profile["core_channel"]
            app["base"] = base
    return documents


def render_machine(
    documents: list[dict],
    release: str,
    base: str,
    machine_channel: str = "",
    microceph_channel: str = "",
    microovn_channel: str = "",
    ovn_proxy_channel: str = "",
    token_distributor_channel: str = "",
) -> list[dict]:
    profile = release_profile(release)
    base_profile = profile.get("base_overrides", {}).get(base, {})
    if base_profile.get("preserve_channels"):
        default_machine_channel = ""
        default_microceph_channel = ""
        default_proxy_channel = ""
        snap_channels = {}
    else:
        default_machine_channel = base_profile.get(
            "machine_channel", profile["machine_channel"]
        )
        default_microceph_channel = base_profile.get(
            "microceph_channel", profile["microceph_channel"]
        )
        default_proxy_channel = base_profile.get(
            "ovn_proxy_channel", profile["ovn_proxy_channel"]
        )
        snap_channels = dict(profile["snap_channels"])
        snap_channels.update(base_profile.get("snap_channels", {}))

    machine_channel = machine_channel or default_machine_channel
    microceph_channel = microceph_channel or default_microceph_channel
    microovn_channel = microovn_channel or base_profile.get(
        "microovn_channel", profile["microovn_channel"]
    )
    ovn_proxy_channel = ovn_proxy_channel or default_proxy_channel
    token_distributor_channel = (
        token_distributor_channel or profile["token_distributor_channel"]
    )

    applications = documents[0].get("applications", {})
    for name, app in applications.items():
        if not isinstance(app, dict):
            continue
        if name in MACHINE_APPS:
            if "channel" in app and machine_channel:
                app["channel"] = machine_channel
            app["base"] = base
            if name in snap_channels:
                app.setdefault("options", {})["snap-channel"] = snap_channels[name]
        elif name == "openstack-network-agents":
            # Subordinate charm: it inherits the principal's base and has no
            # placement. Only its charm/snap channel follows the release.
            if "channel" in app and machine_channel:
                app["channel"] = machine_channel
            if name in snap_channels:
                app.setdefault("options", {})["snap-channel"] = snap_channels[name]
        elif name == "microceph":
            if "channel" in app and microceph_channel:
                app["channel"] = microceph_channel
            app["base"] = base
            if microceph_channel and snap_channels:
                app.setdefault("options", {})["snap-channel"] = microceph_channel
        elif name in OVN_MACHINE_APPS:
            channel_key = OVN_MACHINE_APPS[name]
            channel = {
                "microovn_channel": microovn_channel,
                "ovn_proxy_channel": ovn_proxy_channel,
                "token_distributor_channel": token_distributor_channel,
            }[channel_key]
            if "channel" in app and channel:
                app["channel"] = channel
            app["base"] = base
    drop_relations = set(profile.get("drop_machine_relations", ()))
    if drop_relations:
        relations = documents[0].get("relations", [])
        documents[0]["relations"] = [
            rel for rel in relations
            if drop_relations.isdisjoint({str(endpoint) for endpoint in rel})
        ]
    return documents


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--kind", choices=("control-plane", "machine"), required=True)
    parser.add_argument("--release", default="2026.2")
    parser.add_argument(
        "--base",
        default="",
        help=(
            "Ubuntu base to apply, e.g. ubuntu@26.04; defaults to the release "
            "profile, or the latest known base for a new release"
        ),
    )
    parser.add_argument("--machine-channel", default="")
    parser.add_argument("--microceph-channel", default="")
    parser.add_argument("--microovn-channel", default="")
    parser.add_argument("--ovn-proxy-channel", default="")
    parser.add_argument("--token-distributor-channel", default="")
    args = parser.parse_args()

    release = resolve_release(args.release)
    profile = release_profile(release)
    base = args.base or profile["base"]
    if not base:
        raise SystemExit(f"no base configured for release {release}")
    documents = load_bundle(args.source)
    if args.kind == "control-plane":
        documents = render_control_plane(documents, release, base)
    else:
        documents = render_machine(
            documents,
            release,
            base,
            args.machine_channel,
            args.microceph_channel,
            args.microovn_channel,
            args.ovn_proxy_channel,
            args.token_distributor_channel,
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    save_bundle(args.output, documents)


if __name__ == "__main__":
    main()
