#!/usr/bin/env python3
"""Configure the instance-bound Web updater without reinstalling application data."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def atomic_bytes(path, data, mode, gid=0):
    temporary = path.with_name(path.name + ".next")
    temporary.write_bytes(data)
    temporary.chmod(mode)
    os.chown(temporary, 0, gid)
    os.replace(temporary, path)


def configure(root, bundle, activate=True, overrides=None):
    root, bundle = Path(root).resolve(), Path(bundle).resolve()
    if re.search(r"[\s%]", str(root)):
        raise RuntimeError("Installation path must not contain whitespace or percent signs")
    config_path = root / "run/config.json"
    metadata_path = root / "run/installation.json"
    if config_path.is_symlink() or metadata_path.is_symlink():
        raise RuntimeError("Private control files must not be symbolic links")
    metadata = json.loads(metadata_path.read_text())
    service = metadata["service_name"]
    if not re.fullmatch(r"[a-z][a-z0-9-]{0,40}", service):
        raise RuntimeError("Invalid service identity")
    application = json.loads(config_path.read_text())
    gid = config_path.stat().st_gid
    defaults_path = bundle / "update-settings.json"
    defaults = json.loads(defaults_path.read_text()) if defaults_path.is_file() else {}
    supplied = overrides or {}
    folder = root / "updater"
    existing_path = folder / "config.json"
    existing = json.loads(existing_path.read_text()) if existing_path.is_file() else {}
    if existing and (existing.get("root") != str(root) or existing.get("service_name", service) != service):
        raise RuntimeError("Existing updater belongs to another instance")
    feed = supplied.get("feed_url") or existing.get("feed_url") or defaults.get("feed_url")
    hosts = supplied.get("allowed_hosts") or existing.get("allowed_hosts") or defaults.get("allowed_hosts")
    public_source = supplied.get("public_key")
    if public_source is None and not existing:
        public_source = bundle / defaults.get("public_key_file", "release-signing.pub")
    if not feed or not hosts or (public_source is not None and not Path(public_source).is_file()):
        raise RuntimeError("Upgrade to an official bundle containing update settings and its public key")
    if not (bundle / "update-agent.py").is_file():
        raise RuntimeError("Bundle is missing the update executor")
    folder.mkdir(mode=0o750, exist_ok=True)
    os.chown(folder, 0, gid)
    folder.chmod(0o750)
    atomic_bytes(folder / "update-agent.py", (bundle / "update-agent.py").read_bytes(), 0o700)
    public_target = folder / "release-signing.pub"
    if public_source is not None:
        atomic_bytes(public_target, Path(public_source).read_bytes(), 0o600)
    elif existing.get("public_key"):
        public_target = Path(existing["public_key"])
    if not public_target.is_file() or public_target.is_symlink():
        raise RuntimeError("Trusted public key is unavailable")
    socket = str(folder / "agent.sock")
    settings = dict(existing)
    settings.update(root=str(root), service_name=service, socket=socket, socket_gid=gid,
                    feed_url=feed, allowed_hosts=hosts, public_key=str(public_target))
    atomic_bytes(existing_path, (json.dumps(settings, indent=2) + "\n").encode(), 0o600)
    # The privileged executor may not trust control files writable by the business service.
    for directory in [root, root / "run"]:
        os.chown(directory, 0, gid)
        directory.chmod(0o750)
    for name in ["config.json", "installation.json", "apns.json", "database.env"]:
        control = root / "run" / name
        if control.exists():
            if control.is_symlink():
                raise RuntimeError("Private control files must not be symbolic links")
            os.chown(control, 0, gid)
            control.chmod(0o600 if name == "database.env" else 0o640)
    application["update_socket"] = socket
    atomic_bytes(config_path, (json.dumps(application, indent=2) + "\n").encode(), 0o640, gid)
    unit_name = service + "-updater.service"
    unit = "\n".join([
        "[Unit]", "Description=Vao Push local update executor",
        "After=network-online.target docker.service", "Wants=network-online.target",
        "[Service]", "Type=simple", "User=root", "Group=root", "UMask=0077",
        "ExecStart=/usr/bin/python3 " + str(folder / "update-agent.py") + " --config " + str(existing_path),
        "Restart=on-failure", "RestartSec=3", "NoNewPrivileges=true",
        "[Install]", "WantedBy=multi-user.target", "",
    ])
    atomic_bytes(folder / unit_name, unit.encode(), 0o600)
    if activate:
        if shutil.which("openssl") is None:
            raise RuntimeError("OpenSSL is required to verify signed updates")
        destination = Path("/etc/systemd/system") / unit_name
        if destination.exists() and str(folder / "update-agent.py") not in destination.read_text():
            raise RuntimeError("A different update service already uses this name")
        atomic_bytes(destination, unit.encode(), 0o644)
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        # An active executor may be running this upgrade. Do not terminate it midway.
        active = subprocess.run(["systemctl", "is-active", "--quiet", unit_name]).returncode == 0
        subprocess.run(["systemctl", "enable", unit_name], check=True, stdout=subprocess.DEVNULL)
        if not active:
            subprocess.run(["systemctl", "start", unit_name], check=True)
    return settings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--feed-url")
    parser.add_argument("--public-key", type=Path)
    parser.add_argument("--allow-host", action="append")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--no-restart-app", action="store_true")
    args = parser.parse_args()
    if os.geteuid() != 0:
        parser.error("Run the updater setup as root")
    configure(args.root, Path(__file__).resolve().parent, not args.prepare_only,
              {"feed_url": args.feed_url, "public_key": args.public_key, "allowed_hosts": args.allow_host})
    if not args.prepare_only and not args.no_restart_app:
        service = json.loads((args.root / "run/installation.json").read_text())["service_name"]
        subprocess.run(["systemctl", "restart", service + ".service"], check=True)
    print("Web updates configured. Application data and existing instance identity were kept.")


if __name__ == "__main__":
    main()
