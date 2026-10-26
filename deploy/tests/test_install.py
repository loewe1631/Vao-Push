import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

INSTALLER=Path(os.environ.get('VAO_INSTALLER_SOURCE',Path(__file__).resolve().parents[1]/'install.py'))
spec=importlib.util.spec_from_file_location('vao_install_under_test',INSTALLER)
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)

class InstallerPermissions(unittest.TestCase):
    def test_umask_and_resume_layout(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)/'deployment'
            previous=os.umask(0o077)
            try:
                installer.ensure_installation_layout(root)
                self.assertEqual(root.stat().st_mode & 0o777,0o755)
                self.assertEqual((root/'releases').stat().st_mode & 0o777,0o755)
                for name in ['run','data','backups']:
                    self.assertEqual((root/name).stat().st_mode & 0o777,0o700)
                config=root/'run/config.json';config.write_text('{"existing":"keep"}')
                before=config.read_bytes()
                root.chmod(0o700);(root/'releases').chmod(0o700)
                installer.ensure_installation_layout(root)
                self.assertEqual(root.stat().st_mode & 0o777,0o755)
                self.assertEqual((root/'releases').stat().st_mode & 0o777,0o755)
                self.assertEqual(config.read_bytes(),before)
                self.assertEqual(config.stat().st_mode & 0o777,0o600)
            finally:os.umask(previous)

    def test_resume_summary_retains_original_credentials(self):
        config={'public_url':'https://example.invalid','web_url':'https://example.invalid','bootstrap_username':'admin','bootstrap_password':'test-only-password-24chars'}
        old=json.dumps(config,sort_keys=True)
        for language in ['zh','en']:
            installer.LANG=language
            output=io.StringIO()
            with contextlib.redirect_stdout(output):installer.print_installation_summary(Path('/opt/example'),config,{'official_push_identity':False})
            self.assertIn(config['bootstrap_password'],output.getvalue())
            self.assertIn(config['public_url'],output.getvalue())
            self.assertIn(config['bootstrap_username'],output.getvalue())
        self.assertEqual(json.dumps(config,sort_keys=True),old)

    @unittest.skipUnless(os.environ.get('VAO_INSTALLER_BUNDLE'),'Requires prebuilt bundle')
    def test_shell_entrypoint_and_resume(self):
        bundle=Path(os.environ['VAO_INSTALLER_BUNDLE'])
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)/'installation';answers=Path(directory)/'answers.json'
            answers.write_text(json.dumps({'language':'2','host':'192.0.2.10','mode':'1'}))
            command=['bash',str(bundle/'install.sh'),'--prefix',str(root),'--answers',str(answers),'--prepare-only','--non-interactive']
            initial=subprocess.run(command,capture_output=True,text=True,timeout=20)
            self.assertEqual(initial.returncode,0,initial.stderr)
            self.assertEqual(root.stat().st_mode & 0o777,0o755)
            self.assertEqual((root/'releases').stat().st_mode & 0o777,0o755)
            config=(root/'run/config.json');before=config.read_bytes();parsed=json.loads(before)
            self.assertEqual(len(parsed['bootstrap_password']),24)
            self.assertEqual(config.stat().st_mode & 0o777,0o600)
            resumed=subprocess.run(command+['--resume'],capture_output=True,text=True,timeout=20)
            self.assertEqual(resumed.returncode,0,resumed.stderr)
            self.assertIn(parsed['bootstrap_password'],resumed.stdout)
            self.assertEqual(config.read_bytes(),before)

if __name__=='__main__':unittest.main()
