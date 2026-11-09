#!/usr/bin/env python3
"""Local-only, signed-release updater. Install with deploy/install-update-agent.py."""
import argparse,base64,datetime,fcntl,time,hashlib,http.server,importlib.util,json,os,platform,re,shutil,socketserver,subprocess,tarfile,tempfile,threading,urllib.parse,urllib.request,urllib.error,uuid
from pathlib import Path

class UpdateError(Exception):pass

def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def version(value,allow_pre=False):
    match=re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(rc)\.(0|[1-9][0-9]*))?",value or '')
    if not match or (match[4] and not allow_pre):raise UpdateError('Unsupported release version')
    return tuple(int(match[i]) for i in (1,2,3))+(0 if match[4] else 1,int(match[5] or 0))
class RestrictedRedirect(urllib.request.HTTPRedirectHandler):
    max_redirections=3
    max_repeats=2
    def __init__(self,validate):self.validate=validate
    def redirect_request(self,request,fp,code,message,headers,newurl):
        self.validate(newurl)
        return super().redirect_request(request,fp,code,message,headers,newurl)
class Agent:
    def __init__(self,config):
        self.config=config;self.root=Path(config['root']).resolve();self.directory=self.root/'updates';self.directory.mkdir(mode=0o700,exist_ok=True)
        self.service=config.get('service_name');self.verify_instance();self.path=self.directory/'state.json';self.lock=threading.RLock();self.state={'checked_at':None,'available':None,'task':None}
        if self.path.exists():self.state=json.loads(self.path.read_text())
        if self.state.get('task',{} ) and self.state['task'].get('status')=='running':
            self.state['task'].update(status='interrupted',stage='interrupted',message='Updater restarted; inspect the running version before retrying.');self.save()
    def verify_instance(self):
        metadata=json.loads((self.root/'run/installation.json').read_text())
        if self.service and metadata['service_name']!=self.service:raise UpdateError('Installed service identity changed')
        if not self.config.get('test_loopback',False):
            for path in [self.root,self.root/'run',self.root/'run/config.json',self.root/'run/installation.json',self.root/'current',self.root/'current/manage.py']:
                actual=path.resolve() if path.name=='current' else path
                st=actual.lstat()
                if actual.is_symlink() or st.st_uid!=0 or st.st_mode&0o022:raise UpdateError('Upgrade control files must be root owned and protected')
    def current(self):return json.loads((self.root/'run/installation.json').read_text())['version']
    def save(self):
        temp=self.path.with_suffix('.next');temp.write_text(json.dumps(self.state));temp.chmod(0o600);os.replace(temp,self.path)
    def status(self):
        with self.lock:return dict(json.loads(json.dumps(self.state)),current_version=self.current())
    def allowed(self,url):
        u=urllib.parse.urlsplit(url)
        local=self.config.get('test_loopback',False) and u.hostname in ('127.0.0.1','localhost') and u.scheme=='http'
        if (u.scheme!='https' and not local) or u.username or u.password or u.fragment or u.hostname not in self.config['allowed_hosts']:raise UpdateError('Unapproved update source')
    def download(self,url,limit,destination=None):
        # Restart partial downloads and retry only transient transport failures. Signature,
        # checksum, host restrictions and archive validation remain fail-closed.
        started=time.monotonic();budget=180 if destination else 14
        for attempt in range(3):
            remaining=budget-(time.monotonic()-started)
            if remaining<=0:raise UpdateError('Update download timed out')
            try:return self.download_once(url,limit,destination,min(5 if destination is None else 20,remaining),started+budget)
            except urllib.error.HTTPError as error:
                if error.code not in (408,429,500,502,503,504) or attempt==2:raise
            except (urllib.error.URLError,TimeoutError,ConnectionError):
                if attempt==2:raise
            if time.monotonic()-started>=budget:raise UpdateError('Update download timed out')
            time.sleep(0.25*(attempt+1))
    def download_once(self,url,limit,destination,timeout,deadline):
        self.allowed(url);opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),RestrictedRedirect(self.allowed))
        req=urllib.request.Request(url,headers={'User-Agent':'VaoPush-Updater/1','Accept':'application/json' if destination is None else 'application/octet-stream'})
        with opener.open(req,timeout=timeout) as response:
            if response.status!=200:raise UpdateError('Update source unavailable')
            total=0;chunks=[]
            output=destination.open('wb') if destination else None
            try:
                while True:
                    if time.monotonic()>deadline:raise UpdateError('Update download timed out')
                    data=response.read(min(65536,limit-total+1))
                    if not data:break
                    total+=len(data)
                    if total>limit:raise UpdateError('Download exceeds declared limit')
                    if output:output.write(data)
                    else:chunks.append(data)
            finally:
                if output:output.close()
        return total if destination else b''.join(chunks)
    def releases(self):
        envelope=json.loads(self.download(self.config['feed_url'],1024*1024))
        data=base64.b64decode(envelope['manifest'],validate=True);signature=base64.b64decode(envelope['signature'],validate=True)
        if len(signature)!=64:raise UpdateError('Invalid release signature')
        with tempfile.TemporaryDirectory(dir=self.directory) as d:
            d=Path(d);(d/'manifest').write_bytes(data);(d/'signature').write_bytes(signature)
            result=subprocess.run(['openssl','pkeyutl','-verify','-pubin','-inkey',self.config['public_key'],'-rawin','-in',str(d/'manifest'),'-sigfile',str(d/'signature')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=10)
            if result.returncode:raise UpdateError('Release signature verification failed')
        manifest=json.loads(data)
        if manifest.get('schema_version')!=1 or not isinstance(manifest.get('releases'),list) or len(manifest['releases'])>100:raise UpdateError('Invalid release manifest')
        candidates=[];arch={'x86_64':'amd64','aarch64':'arm64'}.get(platform.machine());current=version(self.current(),True)
        for r in manifest['releases']:
            try:v=version(r['version'],self.config.get('allow_prerelease',False))
            except UpdateError:continue
            if r.get('arch')!=arch or v<=current:continue
            if r.get('backward_compatible') is not True or r.get('database_compatible') is not True:continue
            if version(r['min_server_version'],True)>current or version(r['min_app_version'],True)>version('1.0.0'):continue
            if not re.fullmatch('[a-f0-9]{64}',r.get('sha256','')) or not isinstance(r.get('size'),int) or not 1<=r['size']<=128*1024*1024:raise UpdateError('Invalid package metadata')
            self.allowed(r['url']);r=dict(r);r['release_id']=hashlib.sha256(json.dumps(r,sort_keys=True,separators=(',',':')).encode()).hexdigest();candidates.append((v,r))
        return max(candidates,key=lambda x:x[0])[1] if candidates else None
    def check(self):
        with self.lock:
            if self.state.get('task') and self.state['task']['status']=='running':raise UpdateError('An upgrade is already running')
            try:self.state['available']=self.releases();self.state['check_error']=None
            except Exception:
                self.state['available']=None;self.state['check_error']='Update check failed. Verify network, release signature and upgrade compatibility.'
            self.state['checked_at']=now();self.save();return self.status()
    def task(self,stage,message='',**extra):
        with self.lock:self.state['task'].update(stage=stage,message=message,**extra);self.save()
    def install(self,release_id):
        with self.lock:
            if self.state.get('task') and self.state['task']['status']=='running':raise UpdateError('An upgrade is already running')
            r=self.state.get('available')
            if not r or r['release_id']!=release_id:raise UpdateError('Release changed; check again before upgrading')
            self.state['task']={'id':uuid.uuid4().hex,'target_version':r['version'],'status':'running','stage':'downloading','started_at':now(),'message':''};self.save()
            threading.Thread(target=self.perform,args=(dict(r),),daemon=True).start();return self.status()
    def perform(self,r):
        try:
            self.verify_instance()
            module_path=self.root/'current/manage.py';spec=importlib.util.spec_from_file_location('vao_upgrade',module_path);manager=importlib.util.module_from_spec(spec);spec.loader.exec_module(manager)
            with manager.upgrade_lock(self.root):
                if version(self.current(),True)>=version(r['version'],True):raise UpdateError('Release is no longer newer')
                with tempfile.TemporaryDirectory(dir=self.directory) as temp:
                    temp=Path(temp);archive=temp/'bundle.tar.gz';count=self.download(r['url'],r['size'],archive)
                    self.task('verifying')
                    if count!=r['size'] or hashlib.sha256(archive.read_bytes()).hexdigest()!=r['sha256']:raise UpdateError('Package checksum verification failed')
                    bundle=temp/'bundle';bundle.mkdir();self.extract(archive,bundle)
                    info=manager.validate_bundle(bundle)
                    if info.get('version')!=r['version'] or info.get('arch')!=r['arch'] or info.get('platform')!='linux':raise UpdateError('Package identity does not match the signed release')
                    self.task('backup')
                    original_backup=manager.backup
                    def backup(root):
                        result=original_backup(root);self.task('installing');return result
                    manager.backup=backup
                    # Logs may contain private local paths; never return them to the Web API.
                    log=(self.directory/('task-'+self.state['task']['id']+'.log')).open('w');os.chmod(log.name,0o600)
                    import contextlib
                    with log,contextlib.redirect_stdout(log),contextlib.redirect_stderr(log):manager.upgrade_locked(self.root,bundle)
                self.task('completed',status='completed',finished_at=now());self.state['available']=None;self.save()
        except Exception as error:
            # Do not dump configuration, environment or credentials into UI state.
            self.task('failed','Upgrade did not complete. The previous compatible program was preserved or recovery was attempted; inspect service health and the private task log.',status='failed',finished_at=now())
    @staticmethod
    def extract(archive,bundle):
        with tarfile.open(archive,'r:gz') as tar:
            members=tar.getmembers();total=0;seen=set()
            if len(members)>10000:raise UpdateError('Too many package entries')
            for m in members:
                name=Path(m.name)
                if name.is_absolute() or '..' in name.parts or m.name in seen or not(m.isfile() or m.isdir()):raise UpdateError('Unsafe package path')
                seen.add(m.name);total+=m.size
                if total>512*1024*1024:raise UpdateError('Expanded package too large')
            tar.extractall(bundle)
            # Every member was validated above; reject links and unsafe paths before extraction.
            # Explicit modes keep public runtime files usable under umask 077.
            for path in bundle.rglob('*'):
                private=path.relative_to(bundle).parts[0]=='private'
                path.chmod((0o700 if private else 0o755) if path.is_dir() else (0o600 if private else 0o755 if path.relative_to(bundle).as_posix()=='bin/vao-push' else 0o644))

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def respond(self,status,data):
        body=json.dumps(data).encode();self.send_response(status);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def do_GET(self):
        if self.path!='/state':return self.respond(404,{'error':'Not found'})
        self.respond(200,self.server.agent.status())
    def do_POST(self):
        try:
            size=int(self.headers.get('Content-Length','0'))
            if not 0<=size<=4096:raise UpdateError('Invalid request size')
            body=json.loads(self.rfile.read(size) or '{}')
            if self.path=='/check':return self.respond(200,self.server.agent.check())
            if self.path=='/install' and body.get('confirm') is True:return self.respond(202,self.server.agent.install(body.get('release_id')))
            self.respond(400,{'error':'Invalid update operation'})
        except UpdateError as e:self.respond(409,{'error':str(e)})
        except Exception:self.respond(400,{'error':'Update operation could not be completed'})
class Server(socketserver.ThreadingMixIn,socketserver.UnixStreamServer):daemon_threads=True

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--config',type=Path,required=True);args=parser.parse_args()
    st=args.config.stat()
    if st.st_uid!=os.geteuid() or st.st_mode&0o022:raise SystemExit('Updater config must be owned by the service operator and not writable by others')
    config=json.loads(args.config.read_text());agent=Agent(config);sock=Path(config['socket']);sock.parent.mkdir(mode=0o750,parents=True,exist_ok=True)
    # A second daemon cannot unlink the active socket.
    lockfile=(agent.directory/'agent.lock').open('a');fcntl.flock(lockfile,fcntl.LOCK_EX|fcntl.LOCK_NB)
    sock.unlink(missing_ok=True)
    with Server(str(sock),Handler) as server:
        os.chmod(sock,0o660)
        if config.get('socket_gid') is not None:os.chown(sock,-1,int(config['socket_gid']))
        server.agent=agent;server.serve_forever()
if __name__=='__main__':main()
