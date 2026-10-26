import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PACKAGER = Path(os.environ.get("VAO_PACKAGER_SOURCE", Path(__file__).resolve().parents[1] / "package-release.py"))


class ReleasePackagePermissions(unittest.TestCase):
    def test_restrictive_umask_keeps_runtime_readable_and_identity_private(self):
        previous = os.umask(0o077)
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                binary = root / "server"
                binary.write_bytes(b"test-binary")
                web = root / "web"
                (web / "assets").mkdir(parents=True)
                (web / "index.html").write_text('<div id="app"></div>')
                (web / "assets/app.js").write_text("export const ready = true;")
                identity = root / "identity.json"
                identity.write_text(json.dumps({
                    "environment": "production",
                    "topic": "app.vaovao.push",
                    "key_id": "ABCDEFGHIJ",
                    "team_id": "KLMNOPQRST",
                    "private_key": "synthetic PRIVATE KEY test value",
                }))
                result = subprocess.run([
                    "python3", str(PACKAGER), "--version", "test-permissions",
                    "--arch", "amd64", "--binary", str(binary), "--web", str(web),
                    "--out", str(root / "out"), "--candidate", "--apns-file", str(identity),
                ], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                bundle = root / "out/vao-push-test-permissions-linux-amd64"
                for relative in ["bin", "web", "web/assets"]:
                    self.assertEqual((bundle / relative).stat().st_mode & 0o777, 0o755, relative)
                self.assertEqual((bundle / "bin/vao-push").stat().st_mode & 0o777, 0o755)
                for relative in ["web/index.html", "web/assets/app.js"]:
                    self.assertEqual((bundle / relative).stat().st_mode & 0o777, 0o644, relative)
                self.assertEqual((bundle / "private").stat().st_mode & 0o777, 0o700)
                self.assertEqual((bundle / "private/apns.json").stat().st_mode & 0o777, 0o600)
                manifest = json.loads((bundle / "bundle.json").read_text())
                self.assertTrue(manifest["official_push_identity"])
                for name, digest in manifest["files"].items():
                    self.assertEqual(hashlib.sha256((bundle / name).read_bytes()).hexdigest(), digest, name)
        finally:
            os.umask(previous)


if __name__ == "__main__":
    unittest.main()
