import importlib.util,json,os,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('updater_setup',Path(__file__).resolve().parents[1]/'install-update-agent.py');setup=importlib.util.module_from_spec(spec);spec.loader.exec_module(setup)
class SetupTests(unittest.TestCase):
 def fixture(self,directory):
  root=Path(directory)/'instance';bundle=Path(directory)/'bundle';(root/'run').mkdir(parents=True);bundle.mkdir()
  config={'server_id':'srv_example','master_key':'keep-master-key','bootstrap_password':'keep-password','listen':'127.0.0.1:8188'}
  (root/'run/config.json').write_text(json.dumps(config));(root/'run/installation.json').write_text(json.dumps({'version':'1.0.0','service_name':'vao-example'}))
  (bundle/'update-agent.py').write_text('pass\n');(bundle/'release-signing.pub').write_text('public key fixture')
  (bundle/'update-settings.json').write_text(json.dumps({'feed_url':'https://example.com/releases.json','allowed_hosts':['example.com'],'public_key_file':'release-signing.pub'}))
  return root,bundle,config
 def test_adds_only_update_socket_and_preserves_identity(self):
  with tempfile.TemporaryDirectory() as directory,patch.object(setup.os,'chown'):
   root,bundle,original=self.fixture(directory);result=setup.configure(root,bundle,activate=False)
   config=json.loads((root/'run/config.json').read_text());self.assertEqual({k:v for k,v in config.items() if k!='update_socket'},original)
   self.assertEqual(result['service_name'],'vao-example');self.assertEqual(result['root'],str(root));self.assertTrue((root/'updater/release-signing.pub').is_file())
 def test_existing_custom_feed_and_key_are_not_replaced(self):
  with tempfile.TemporaryDirectory() as directory,patch.object(setup.os,'chown'):
   root,bundle,_=self.fixture(directory);first=setup.configure(root,bundle,activate=False)
   first.update(feed_url='https://custom.example/feed.json',allowed_hosts=['custom.example'])
   (root/'updater/config.json').write_text(json.dumps(first));key=root/'updater/release-signing.pub';key.write_text('pinned custom key')
   second=setup.configure(root,bundle,activate=False)
   self.assertEqual(second['feed_url'],first['feed_url']);self.assertEqual(key.read_text(),'pinned custom key')
 def test_active_executor_is_not_restarted_during_its_own_upgrade(self):
  with tempfile.TemporaryDirectory() as directory,patch.object(setup.os,'chown'):
   root,bundle,_=self.fixture(directory);setup.configure(root,bundle,activate=False)
   unit_directory=Path(directory)/'systemd';unit_directory.mkdir();old_path=setup.Path
   def path(value):return unit_directory if value=='/etc/systemd/system' else old_path(value)
   with patch.object(setup,'Path',side_effect=path),patch.object(setup.subprocess,'run') as run:
    run.return_value.returncode=0
    setup.configure(root,bundle,activate=True)
    commands=[call.args[0] for call in run.call_args_list]
   self.assertFalse(any('restart' in command or 'stop' in command for command in commands));self.assertFalse(any('start' in command for command in commands))
 def test_different_instance_cannot_reuse_updater(self):
  with tempfile.TemporaryDirectory() as directory,patch.object(setup.os,'chown'):
   root,bundle,_=self.fixture(directory);first=setup.configure(root,bundle,activate=False);first['service_name']='another-instance';(root/'updater/config.json').write_text(json.dumps(first))
   with self.assertRaises(RuntimeError):setup.configure(root,bundle,activate=False)
if __name__=='__main__':unittest.main()
