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


    def test_failed_start_restores_previous_and_rechecks_health(self):
        with tempfile.TemporaryDirectory() as directory:
            parent=Path(directory);root=parent/'root';(root/'run').mkdir(parents=True);(root/'releases/old/bin').mkdir(parents=True)
            (root/'releases/old/bin/vao-push').write_bytes(b'old');(root/'current').symlink_to(root/'releases/old')
            (root/'run/config.json').write_text(json.dumps({'listen':'127.0.0.1:8188'}));(root/'run/installation.json').write_text(json.dumps({'service_name':'test','version':'old'}))
            bundle=self._bundle(parent);checks=[]
            old_run,old_backup,old_healthy=manage.run,manage.backup,manage.healthy
            try:
                manage.run=lambda *a,**k:None;manage.backup=lambda *a,**k:None
                def healthy(root):checks.append((root/'current').resolve().name);return checks[-1]=='old'
                manage.healthy=healthy
                with self.assertRaises(RuntimeError):manage.upgrade(root,bundle)
            finally:manage.run,manage.backup,manage.healthy=old_run,old_backup,old_healthy
            self.assertEqual(checks,['new','old']);self.assertEqual((root/'current').resolve().name,'old');self.assertEqual(json.loads((root/'run/installation.json').read_text())['version'],'old')

    def test_same_version_refresh_uses_a_new_directory_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            parent=Path(directory);root=parent/'root';(root/'run').mkdir(parents=True)
            previous=root/'releases/1.1.0';(previous/'bin').mkdir(parents=True)
            (previous/'bin/vao-push').write_bytes(b'old binary')
            files={'bin/vao-push':hashlib.sha256(b'old binary').hexdigest()}
            (previous/'bundle.json').write_text(json.dumps({'version':'1.1.0','files':files}))
            (root/'current').symlink_to(previous)
            (root/'run/config.json').write_text(json.dumps({'listen':'127.0.0.1:8188','apns_identity_file':'/private/existing'}))
            (root/'run/installation.json').write_text(json.dumps({'service_name':'test','version':'1.1.0'}))
            bundle=self._bundle(parent,'1.1.0')
            old_run,old_backup,old_healthy=manage.run,manage.backup,manage.healthy
            backups=[]
            try:
                manage.run=lambda *a,**k:None
                manage.backup=lambda *a,**k:backups.append(True)
                manage.healthy=lambda *a,**k:True
                manage.upgrade(root,bundle)
                selected=(root/'current').resolve()
                self.assertTrue(selected.name.startswith('1.1.0-'))
                self.assertEqual((previous/'bin/vao-push').read_bytes(),b'old binary')
                self.assertEqual((selected/'bin/vao-push').read_bytes(),b'new binary')
                self.assertEqual(json.loads((root/'run/installation.json').read_text())['version'],'1.1.0')
                manage.upgrade(root,bundle)
                self.assertEqual((root/'current').resolve(),selected)
                self.assertEqual(len(backups),1)
            finally:manage.run,manage.backup,manage.healthy=old_run,old_backup,old_healthy

    def test_same_version_refresh_failure_restores_original_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            parent=Path(directory);root=parent/'root';(root/'run').mkdir(parents=True)
            previous=root/'releases/1.1.0';(previous/'bin').mkdir(parents=True)
            (previous/'bin/vao-push').write_bytes(b'old')
            (previous/'bundle.json').write_text(json.dumps({'version':'1.1.0','files':{'bin/vao-push':hashlib.sha256(b'old').hexdigest()}}))
            (root/'current').symlink_to(previous)
            (root/'run/config.json').write_text(json.dumps({'listen':'127.0.0.1:8188','apns_identity_file':'/private/existing'}))
            (root/'run/installation.json').write_text(json.dumps({'service_name':'test','version':'1.1.0'}))
            bundle=self._bundle(parent,'1.1.0')
            old_run,old_backup,old_healthy=manage.run,manage.backup,manage.healthy
            try:
                manage.run=lambda *a,**k:None;manage.backup=lambda *a,**k:None
                manage.healthy=lambda r:(r/'current').resolve()==previous
                with self.assertRaises(RuntimeError):manage.upgrade(root,bundle)
                self.assertEqual((root/'current').resolve(),previous)
                self.assertEqual((previous/'bin/vao-push').read_bytes(),b'old')
            finally:manage.run,manage.backup,manage.healthy=old_run,old_backup,old_healthy


if __name__ == "__main__":
    unittest.main()
