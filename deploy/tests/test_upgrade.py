import importlib.util
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest

MANAGE = Path(os.environ.get("VAO_MANAGE_SOURCE", Path(__file__).resolve().parents[1] / "manage.py"))
spec = importlib.util.spec_from_file_location("vao_manage_under_test", MANAGE)
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


class PackagedIdentityUpgrade(unittest.TestCase):
    def _bundle(self, parent, version="new"):
        bundle = parent / "bundle"
        (bundle / "bin").mkdir(parents=True)
        (bundle / "private").mkdir()
        (bundle / "bin/vao-push").write_bytes(b"new binary")
        (bundle / "private/apns.json").write_text('{"key_id":"ABCDEFGHIJ"}')
        files = {
            str(path.relative_to(bundle)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(bundle.rglob("*")) if path.is_file()
        }
        (bundle / "bundle.json").write_text(json.dumps({
            "version": version,
            "files": files,
            "official_push_identity": True,
        }))
        return bundle

    def test_candidate_upgrade_imports_identity_without_overwriting_configured_one(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            (root / "run").mkdir(parents=True)
            config_path = root / "run/config.json"
            config_path.write_text(json.dumps({"listen": "127.0.0.1:8188"}))
            bundle = Path(directory) / "bundle"
            (bundle / "private").mkdir(parents=True)
            source = bundle / "private/apns.json"
            source.write_text('{"key_id":"ABCDEFGHIJ"}')
            config = json.loads(config_path.read_text())
            target = manage.prepare_packaged_identity(
                root, bundle, {"official_push_identity": True}, config
            )
            self.assertEqual(target, root / "run/apns.json")
            self.assertEqual(config["apns_identity_file"], str(target))
            self.assertEqual(target.read_text(), source.read_text())
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)

            configured = {"apns_identity_file": "/private/operator/apns.json"}
            self.assertIsNone(
                manage.prepare_packaged_identity(root, bundle, {"official_push_identity": True}, configured)
            )
            self.assertEqual(configured["apns_identity_file"], "/private/operator/apns.json")

    def test_unreferenced_identity_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "root"
            (root / "run").mkdir(parents=True)
            (root / "run/config.json").write_text("{}")
            (root / "run/apns.json").write_text("existing")
            bundle = Path(directory) / "bundle"
            (bundle / "private").mkdir(parents=True)
            (bundle / "private/apns.json").write_text("new")
            with self.assertRaises(RuntimeError):
                manage.prepare_packaged_identity(
                    root, bundle, {"official_push_identity": True}, {}
                )
            self.assertEqual((root / "run/apns.json").read_text(), "existing")

    def test_upgrade_switches_release_and_records_imported_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            root = parent / "root"
            (root / "run").mkdir(parents=True)
            (root / "releases/old/bin").mkdir(parents=True)
            (root / "releases/old/bin/vao-push").write_bytes(b"old binary")
            (root / "current").symlink_to(root / "releases/old")
            (root / "run/config.json").write_text(json.dumps({"listen": "127.0.0.1:8188"}))
            (root / "run/installation.json").write_text(json.dumps({"service_name": "test", "version": "old"}))
            bundle = self._bundle(parent)

            old_run = manage.run
            old_backup = manage.backup
            old_healthy = manage.healthy
            try:
                manage.run = lambda *args, **kwargs: None
                manage.backup = lambda *_args, **_kwargs: None
                manage.healthy = lambda *_args, **_kwargs: True
                manage.upgrade(root, bundle)
            finally:
                manage.run = old_run
                manage.backup = old_backup
                manage.healthy = old_healthy

            self.assertEqual(os.path.realpath(root / "current"), os.path.realpath(root / "releases/new"))
            config = json.loads((root / "run/config.json").read_text())
            self.assertEqual(config["apns_identity_file"], str(root / "run/apns.json"))
            self.assertEqual((root / "run/apns.json").read_text(), '{"key_id":"ABCDEFGHIJ"}')
            self.assertEqual(json.loads((root / "run/installation.json").read_text())["version"], "new")


if __name__ == "__main__":
    unittest.main()
