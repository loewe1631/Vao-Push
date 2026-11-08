import base64,hashlib,importlib.util,io,json,os,subprocess,tarfile,tempfile,threading,time,unittest
from pathlib import Path
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from functools import partial
spec=importlib.util.spec_from_file_location('agent',Path(__file__).resolve().parents[1]/'update-agent.py');agent=importlib.util.module_from_spec(spec);spec.loader.exec_module(agent)
class Quiet(SimpleHTTPRequestHandler):
 def do_GET(self):
  if self.path=='/redirect-unsafe':self.send_response(302);self.send_header('Location','https://example.com/unapproved');self.end_headers();return
  return super().do_GET()
 def log_message(self,*args):pass
class UpdateAgentTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.base=Path(self.tmp.name);self.root=self.base/'root';(self.root/'run').mkdir(parents=True);(self.root/'run/installation.json').write_text(json.dumps({'version':'1.1.0-rc.1','service_name':'test'}))
  self.key=self.base/'private.pem';self.public=self.base/'public.pem'
  subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(self.key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  subprocess.run(['openssl','pkey','-in',str(self.key),'-pubout','-out',str(self.public)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  self.web=ThreadingHTTPServer(('127.0.0.1',0),partial(Quiet,directory=str(self.base)));threading.Thread(target=self.web.serve_forever,daemon=True).start();self.url='http://127.0.0.1:'+str(self.web.server_port)
  self.config={'root':str(self.root),'feed_url':self.url+'/feed.json','public_key':str(self.public),'allowed_hosts':['127.0.0.1'],'test_loopback':True,'allow_prerelease':True,'service_name':'test'}
 def tearDown(self):self.web.shutdown();self.web.server_close();self.tmp.cleanup()
 def feed(self,release,corrupt=False):
  data=json.dumps({'schema_version':1,'releases':[release]}).encode();(self.base/'manifest').write_bytes(data)
  subprocess.run(['openssl','pkeyutl','-sign','-inkey',str(self.key),'-rawin','-in',str(self.base/'manifest'),'-out',str(self.base/'sig')],check=True)
  if corrupt:data+=b' '
  (self.base/'feed.json').write_text(json.dumps({'manifest':base64.b64encode(data).decode(),'signature':base64.b64encode((self.base/'sig').read_bytes()).decode()}))
 def release(self):return {'version':'1.1.0-rc.2','arch':'amd64' if agent.platform.machine()=='x86_64' else 'arm64','min_server_version':'1.0.0','min_app_version':'1.0.0','backward_compatible':True,'database_compatible':True,'url':self.url+'/bundle.tar.gz','sha256':'1'*64,'size':10,'notes':'Test release'}
 def test_signed_check_pin_and_tamper(self):
  r=self.release();self.feed(r);a=agent.Agent(self.config);s=a.check();self.assertEqual(s['available']['version'],r['version']);self.assertEqual(len(s['available']['release_id']),64)
  with self.assertRaises(agent.UpdateError):a.install('0'*64)
  self.feed(r,True);s=a.check();self.assertIsNone(s['available']);self.assertTrue(s['check_error'])
 def test_incompatible_release_not_offered(self):
  for key,value in [('min_app_version','1.1.0'),('backward_compatible',False),('database_compatible',False),('min_server_version','2.0.0')]:
   r=self.release();r[key]=value;self.feed(r);self.assertIsNone(agent.Agent(self.config).check()['available'])
 def test_unapproved_source_and_unsafe_archive(self):
  a=agent.Agent(self.config)
  for u in ['http://example.com/a','https://example.com/a','http://u:p@127.0.0.1/a','file:///etc/passwd']:
   with self.assertRaises(agent.UpdateError):a.allowed(u)
  for name,kind in [('../escape',tarfile.REGTYPE),('/absolute',tarfile.REGTYPE),('link',tarfile.SYMTYPE)]:
   f=self.base/'unsafe.tar.gz'
   with tarfile.open(f,'w:gz') as t:m=tarfile.TarInfo(name);m.type=kind;m.linkname='/etc/passwd';t.addfile(m)
   with self.assertRaises(agent.UpdateError):agent.Agent.extract(f,self.base/'extracted')
 def test_restrictive_umask_keeps_public_directories_traversable(self):
  archive=self.base/'public.tar.gz'
  with tarfile.open(archive,'w:gz') as tar:
   for name in ['bin','web','private']:
    m=tarfile.TarInfo(name);m.type=tarfile.DIRTYPE;m.mode=0o755;tar.addfile(m)
   for name in ['bin/vao-push','web/index.html','private/apns.json']:
    m=tarfile.TarInfo(name);m.size=1;m.mode=0o644;tar.addfile(m,io.BytesIO(b'x'))
  dest=self.base/'extracted';dest.mkdir();old=os.umask(0o077)
  try:agent.Agent.extract(archive,dest)
  finally:os.umask(old)
  self.assertEqual((dest/'bin').stat().st_mode&0o777,0o755);self.assertEqual((dest/'web').stat().st_mode&0o777,0o755);self.assertEqual((dest/'private').stat().st_mode&0o777,0o700)
 def test_redirect_revalidates_destination(self):
  a=agent.Agent(self.config)
  with self.assertRaises(agent.UpdateError):a.download(self.url+'/redirect-unsafe',1024)
 def test_interrupted_task_not_reexecuted(self):
  a=agent.Agent(self.config);a.state['task']={'status':'running','stage':'installing','id':'old'};a.save();b=agent.Agent(self.config)
  self.assertEqual(b.status()['task']['status'],'interrupted')
 def test_instance_metadata_cannot_select_another_service(self):
  self.config['service_name']='other'
  with self.assertRaises(agent.UpdateError):agent.Agent(self.config)
 def test_versions_are_semantic(self):
  self.assertGreater(agent.version('1.10.0'),agent.version('1.9.0'));self.assertGreater(agent.version('1.1.0'),agent.version('1.1.0-rc.2',True))
  for v in ['v1.0.0','1.0','../x','01.0.0']:
   with self.assertRaises(agent.UpdateError):agent.version(v)
if __name__=='__main__':unittest.main()
