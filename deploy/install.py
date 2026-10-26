#!/usr/bin/env python3
"""Interactive installer for a prebuilt Linux Vao Push bundle."""
import argparse
import getpass
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

LANG = 'zh'
def tr(zh, en): return zh if LANG == 'zh' else en
def fail(zh, en): raise RuntimeError(tr(zh, en))
def run(args, **kwargs): return subprocess.run(args, check=True, **kwargs)
def prompt(zh, en, default, answers, key, password=False):
    if key in answers: return str(answers[key])
    if ARGS.non_interactive: return str(default)
    label = tr(zh,en) + (' [' + str(default) + ']' if not password else ' ['+tr('回车自动生成','Enter to generate')+']') + ': '
    value = getpass.getpass(label) if password else input(label)
    return value.strip() if value.strip() else str(default)
def private_json(path, value):
    path.write_text(json.dumps(value,ensure_ascii=False,indent=2)+'\n');path.chmod(0o600)
def free_port(preferred):
    for port in range(preferred, min(preferred+1000,65536)):
        try:
            with socket.socket() as s: s.bind(('127.0.0.1',port))
            return port
        except OSError: pass
    fail('找不到可用的内部端口。','No internal port is available.')
def public_ip():
    try:
        with urllib.request.urlopen('https://api.ipify.org',timeout=5) as res: value=res.read(64).decode().strip()
        if ipaddress.ip_address(value).is_global:return value
    except Exception: pass
    return '127.0.0.1'
def port(value):
    value=int(value)
    if not 1<=value<=65535:fail('端口须为1至65535。','Ports must be from 1 to 65535.')
    return value
def origin(host, port, https):
    try:
        if ipaddress.ip_address(host).version==6:host='['+host+']'
    except ValueError:pass
    return ('https' if https else 'http')+'://'+host+(':'+str(port) if port!=(443 if https else 80) else '')
def verify_bundle(bundle):
    manifest=json.loads((bundle/'bundle.json').read_text())
    required={'bin/vao-push','web/index.html','install.py','manage.py','install.sh'}
    if not required.issubset(manifest['files']):fail('安装包缺少必要文件。','The bundle is missing required files.')
    import platform
    arch={'x86_64':'amd64','aarch64':'arm64','arm64':'arm64'}.get(platform.machine())
    if not ARGS.prepare_only and (sys.platform!='linux' or manifest.get('arch')!=arch):fail('安装包与系统或CPU架构不匹配。','The bundle does not match the operating system or CPU architecture.')
    for name, expected in manifest['files'].items():
        path=bundle/name
        if Path(name).is_absolute() or '..' in Path(name).parts or not path.is_file() or path.is_symlink():fail('安装包路径无效。','Invalid bundle path.')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:fail('安装包校验失败。','Bundle checksum verification failed.')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}',manifest['version']):fail('版本标识无效。','Invalid version identifier.')
    return manifest

def make_config(root, bundle, manifest, answers):
    api=port(prompt('服务对外端口','API port',8188,answers,'api_port'))
    web=port(prompt('Web对外端口','Web port',18188,answers,'web_port'))
    if api==web:fail('服务端口和Web端口不能相同。','API and Web ports must differ.')
    username=prompt('Web管理用户名','Web administrator', 'admin',answers,'username')
    password=prompt('Web管理密码（之后可在Web修改）','Web password (can be changed later)',secrets.token_urlsafe(18),answers,'password',True)
    if not username or len(username.encode())>80 or any(ord(c)<32 for c in username):fail('管理用户名无效。','Invalid administrator name.')
    if not 20<=len(password.encode())<=72 or any(c in password for c in '\r\n'):fail('初始密码需20至72字节。','The initial password must have 20 to 72 bytes.')
    print(tr('访问方式：1.IP直连HTTP  2.域名自动HTTPS  3.已有HTTPS反向代理  4.自带HTTPS证书','Access: 1.HTTP by IP  2.Automatic domain HTTPS  3.Existing HTTPS proxy  4.Own HTTPS certificate'))
    mode=prompt('选择访问方式','Access mode','1',answers,'mode')
    if mode not in ['1','2','3','4']:fail('请选择1至4。','Choose 1 to 4.')
    host=prompt('服务器公网IP或域名','Public server IP or hostname',answers.get('host') or public_ip(),answers,'host')
    host=host.lower()
    if not re.fullmatch(r'[A-Za-z0-9.:-]+',host):fail('请输入IP或域名，不带协议和路径。','Enter an IP or hostname without a scheme or path.')
    if mode=='2':
        try:ipaddress.ip_address(host)
        except ValueError:pass
        else:fail('自动域名HTTPS需要域名。无域名请选1。','Automatic domain HTTPS requires a domain; choose 1 when no domain is available.')
    if mode=='1':print(tr('HTTP不会加密传输；之后可配置HTTPS。','HTTP transport is unencrypted. HTTPS can be configured later.'))
    if mode!='3' and not ARGS.prepare_only:
        for candidate in [api,web]+([80] if mode=='2' else []):
            try:
                with socket.socket() as connection:connection.bind(('0.0.0.0',candidate))
            except OSError:fail('端口'+str(candidate)+'已被占用，请换端口或使用已有反向代理。','Port '+str(candidate)+' is occupied. Choose another port or use an existing proxy.')
    certificate_files={}
    if mode=='4':
        for key,name,label in [('certificate','certificate.pem','HTTPS certificate path'),('certificate_key','private-key.pem','HTTPS private key path')]:
            source=Path(prompt(label,label,'',answers,key)).expanduser()
            if not source.is_file():fail('证书文件不存在。','Certificate file not found.')
            certificate_files[name]=source.read_bytes()
    database_port=free_port(55432)
    api_internal=free_port(28188) if mode in ['2','4'] else api
    web_internal=free_port(max(28189,api_internal+1)) if mode in ['2','4'] else web
    password_db=secrets.token_urlsafe(32)
    public_api=origin(host,api,mode!='1')
    public_web=origin(host,web,mode!='1')
    if mode=='3':
        public_api=prompt('App外部HTTPS地址','External App HTTPS address',public_api,answers,'public_url')
        public_web=prompt('Web外部HTTPS地址','External Web HTTPS address',public_web,answers,'web_url')
        from urllib.parse import urlsplit
        for value in [public_api,public_web]:
            u=urlsplit(value)
            if u.scheme!='https' or not u.hostname or u.username or u.password or u.path or u.query or u.fragment:fail('外部地址须为HTTPS，不带尾斜线或路径。','External addresses must use HTTPS without a path or trailing slash.')
    bind='0.0.0.0' if mode=='1' else '127.0.0.1'
    config={'listen':bind+':'+str(api_internal),'web_listen':bind+':'+str(web_internal), 'public_url':public_api,'web_url':public_web,'server_name':'Vao Push','server_id':'srv_'+secrets.token_hex(16),'master_key':secrets.token_hex(32),'database_url':'postgres://vaopush:'+password_db+'@127.0.0.1:'+str(database_port)+'/vaopush?sslmode=disable','bootstrap_username':username,'bootstrap_password':password,'web_dir':str(root/'current/web')}
    if manifest.get('official_push_identity'):
        source=bundle/'private/apns.json'
        if not source.is_file():fail('安装包缺少官方推送身份。','The bundle is missing its official push identity.')
        shutil.copyfile(source,root/'run/apns.json');(root/'run/apns.json').chmod(0o600)
        config['apns_identity_file']=str(root/'run/apns.json')
    private_json(root/'run/config.json',config)
    (root/'run/database.env').write_text('POSTGRES_USER=vaopush\nPOSTGRES_DB=vaopush\nPOSTGRES_PASSWORD='+password_db+'\n');(root/'run/database.env').chmod(0o600)
    private_json(root/'run/installation.json',{'language':LANG,'mode':mode,'api_port':api,'web_port':web,'database_port':database_port,'service_name':ARGS.service_name,'version':manifest['version']})
    if mode in ['2','4']:
        lines=['{','    auto_https disable_redirects','}']
        for address,target in [(public_api,api_internal),(public_web,web_internal)]:
            lines += [address+' {','    reverse_proxy 127.0.0.1:'+str(target)]
            if mode=='4':lines+=['    tls /certs/certificate.pem /certs/private-key.pem']
            lines+=['}']
        (root/'run/Caddyfile').write_text('\n'.join(lines)+'\n')
        if mode=='4':
            certificates=root/'run/certs';certificates.mkdir(mode=0o700,exist_ok=True)
            for name,content in certificate_files.items():
                (certificates/name).write_bytes(content);(certificates/name).chmod(0o600)
    return config

def ensure_installation_layout(root):
    # install.sh deliberately uses umask 077. mkdir(mode=0755) alone would
    # therefore create root-owned 0700 parents that the service cannot traverse.
    root.mkdir(parents=True,exist_ok=True,mode=0o755)
    root.chmod(0o755)
    for name,mode in [('releases',0o755),('run',0o700),('backups',0o700),('data',0o700)]:
        path=root/name
        path.mkdir(exist_ok=True,mode=mode)
        path.chmod(mode)


def print_installation_summary(root, config, manifest):
    print('App: '+config['public_url']);print('Web: '+config.get('web_url',config['public_url']))
    print(tr('用户名：','Username: ')+config['bootstrap_username'])
    print(tr('初始密码：','Initial password: ')+config['bootstrap_password'])
    print(tr('密码之后可在Web修改；如已修改，请使用修改后的密码。','The password can be changed in the Web console. If already changed, use the new password.'))
    print(tr('配置目录：','Configuration: ')+str(root/'run'))
    print(tr('管理命令：','Manage: ')+'sudo python3 '+str(root/'current/manage.py')+' --root '+str(root)+' status')
    if not manifest.get('official_push_identity'):print(tr('当前为未附生产推送身份的开发候选包。','This development candidate does not include the production push identity.'))


def install_services(root, config, metadata):
    ensure_installation_layout(root)
    (root/'current').resolve().chmod(0o755)
    if shutil.which('docker') is None:
        if shutil.which('apt-get') is None:fail('请先安装Docker Engine后用--resume重试；配置已保存。','Install Docker Engine and retry using --resume; configuration was saved.')
        print(tr('正在安装Docker运行依赖。','Installing Docker runtime dependencies.'))
        run(['apt-get','update']);run(['apt-get','install','-y','docker.io'])
        run(['systemctl','enable','--now','docker'])
    if shutil.which('systemctl') is None:fail('此安装方式需要systemd。','This installation requires systemd.')
    unit=ARGS.service_name;container=unit+'-postgres'
    if run(['docker','ps','-a','--filter','name=^/'+container+'$','--format','{{.Names}}'],capture_output=True,text=True).stdout.strip():
        label=run(['docker','inspect','-f','{{ index .Config.Labels "io.vaopush.root" }}',container],capture_output=True,text=True).stdout.strip()
        if label!=str(root):fail('同名数据库容器属于其他部署，已停止以保护原数据。','A database container with this name belongs to another installation; its data was kept.')
        run(['docker','start',container],stdout=subprocess.DEVNULL)
    else:
        run(['docker','run','-d','--name',container,'--label','io.vaopush.root='+str(root),'--restart','unless-stopped','--env-file',str(root/'run/database.env'),'-v',str(root/'data/postgres')+':/var/lib/postgresql/data','-p','127.0.0.1:'+str(metadata['database_port'])+':5432','postgres:16-alpine'],stdout=subprocess.DEVNULL)
    ready=False
    for _ in range(60):
        if subprocess.run(['docker','exec',container,'pg_isready','-U','vaopush','-d','vaopush'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:ready=True;break
        time.sleep(1)
    if not ready:fail('数据库尚未就绪。数据和配置已保留，请检查容器日志。','Database is not ready. Data and configuration were kept; check container logs.')
    account='vaopush'
    if subprocess.run(['id',account],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode:run(['useradd','--system','--home-dir',str(root),'--shell','/usr/sbin/nologin',account])
    import pwd
    user=pwd.getpwnam(account)
    for path in (root/'run').rglob('*'):
        if path.is_dir() or path.name!='database.env':os.chown(path,user.pw_uid,user.pw_gid)
    os.chown(root/'run',user.pw_uid,user.pw_gid)
    service='\n'.join(['[Unit]','Description=Vao Push','After=network-online.target docker.service','Wants=network-online.target','[Service]','User='+account,'Group='+account,'Environment=VAO_CONFIG='+str(root/'run/config.json'),'ExecStart='+str(root/'current/bin/vao-push'),'WorkingDirectory='+str(root),'Restart=on-failure','RestartSec=3','NoNewPrivileges=true','UMask=0077','[Install]','WantedBy=multi-user.target',''])
    unit_path=Path('/etc/systemd/system/'+unit+'.service')
    if unit_path.exists() and 'ExecStart='+str(root/'current/bin/vao-push') not in unit_path.read_text():fail('同名系统服务已存在，已保留原服务。','A different system service with this name already exists and was kept.')
    unit_path.write_text(service)
    run(['systemctl','daemon-reload']);run(['systemctl','enable','--now',unit+'.service'],stdout=subprocess.DEVNULL)
    if metadata['mode'] in ['2','4']:
        args=['docker','run','-d','--name',unit+'-https','--restart','unless-stopped','--network','host','-v',str(root/'run/Caddyfile')+':/etc/caddy/Caddyfile:ro','-v',str(root/'data/caddy')+':/data']
        if metadata['mode']=='4':args+=['-v',str(root/'run/certs')+':/certs:ro']
        existing=run(['docker','ps','-a','--filter','name=^/'+unit+'-https$','--format','{{.Names}}'],capture_output=True,text=True).stdout.strip()
        if existing:
            label=run(['docker','inspect','-f','{{ index .Config.Labels "io.vaopush.root" }}',existing],capture_output=True,text=True).stdout.strip()
            if label!=str(root):fail('同名HTTPS容器属于其他部署，已保留。','A different HTTPS container with this name already exists and was kept.')
            run(['docker','start',existing],stdout=subprocess.DEVNULL)
        else:
            run(args+['--label','io.vaopush.root='+str(root),'caddy:2-alpine'],stdout=subprocess.DEVNULL)
    ready=False
    for _ in range(20):
        try:
            with urllib.request.urlopen('http://127.0.0.1:'+config['web_listen'].rsplit(':',1)[1]+'/healthz',timeout=2) as response:ready=response.status==200
            if ready:break
        except Exception:pass
        time.sleep(1)
    if not ready:fail('服务健康检查未通过。配置已保留，可检查日志后用--resume重试。','Service health check failed. Configuration was kept; check logs and retry with --resume.')
    if metadata['mode'] in ['2','4']:
        for address in [config['public_url'],config['web_url']]:
            secured=False
            for _ in range(10):
                try:
                    with urllib.request.urlopen(address+'/healthz',timeout=3) as response:secured=response.status==200
                    if secured:break
                except Exception:pass
                time.sleep(2)
            if not secured:fail('HTTPS尚未就绪。配置已保留，请检查域名解析、证书及端口后用--resume重试。','HTTPS is not ready. Configuration was kept; check DNS, certificates, and ports, then retry using --resume.')
    print(tr('服务已启动。','Services started.'))

def main():
    global LANG,ARGS
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix',default='/opt/vao-push')
    parser.add_argument('--service-name',default='vao-push')
    parser.add_argument('--answers',type=Path)
    parser.add_argument('--non-interactive',action='store_true')
    parser.add_argument('--resume',action='store_true',help='Resume an installation using its saved configuration')
    parser.add_argument('--prepare-only',action='store_true',help='Generate an installation without changing system services')
    ARGS=parser.parse_args()
    answers=json.loads(ARGS.answers.read_text()) if ARGS.answers else {}
    print('Vao Push / 选择语言 / Select Language: 1.中文  2.English')
    choice=prompt('请选择','Choose','1',answers,'language')
    if choice not in ['1','2']:fail('请选择1或2。','Choose 1 or 2.')
    LANG='zh' if choice=='1' else 'en'
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,40}',ARGS.service_name):fail('服务名称无效。','Invalid service name.')
    root=Path(ARGS.prefix).expanduser().absolute()
    if re.search(r'[\s%\n]',str(root)):fail('安装路径不能包含空格或百分号。','The installation path cannot contain whitespace or percent signs.')
    if (root/'run/config.json').exists():
        if not ARGS.resume:fail('此目录已有配置，已停止以保留原数据。可用--resume继续安装，或用manage.py升级。','Configuration already exists. Use --resume to continue installation or manage.py to upgrade.')
        if os.geteuid()!=0 and not ARGS.prepare_only:fail('请使用sudo运行安装。','Run the installer using sudo.')
        metadata=json.loads((root/'run/installation.json').read_text())
        ARGS.service_name=metadata['service_name']
        manifest=verify_bundle((root/'current').resolve())
        config=json.loads((root/'run/config.json').read_text())
        if not ARGS.prepare_only:install_services(root,config,metadata)
        print(tr('已使用原配置继续安装。','Resumed using the existing configuration.'))
        print_installation_summary(root,config,manifest)
        return
    if not ARGS.prepare_only and os.geteuid()!=0:fail('请使用sudo运行安装。','Run the installer using sudo.')
    bundle=Path(__file__).resolve().parent
    manifest=verify_bundle(bundle)
    ensure_installation_layout(root)
    release=root/'releases'/manifest['version']
    if release.exists():
        existing=verify_bundle(release)
        if existing['files']!=manifest['files']:fail('该版本目录含不同文件，已保留原文件。','The existing release contains different files and was kept.')
    else:shutil.copytree(bundle,release,ignore=shutil.ignore_patterns('__pycache__'))
    release.chmod(0o755)
    (release/'bin/vao-push').chmod(0o755)
    if (root/'current').is_symlink():
        if (root/'current').resolve()!=release.resolve():fail('已有其他活动版本，已保留。','Another release is active and was kept.')
    else:(root/'current').symlink_to(release)
    config=make_config(root,bundle,manifest,answers)
    if not ARGS.prepare_only:install_services(root,config,json.loads((root/'run/installation.json').read_text()))
    print(tr('配置已生成。','Configuration generated.') if ARGS.prepare_only else tr('安装完成。','Installation complete.'))
    print_installation_summary(root,config,manifest)

if __name__=='__main__':
    try:main()
    except (RuntimeError,ValueError,OSError,subprocess.CalledProcessError,KeyError) as error:
        print(tr('安装未完成：','Installation incomplete: ')+str(error),file=sys.stderr);sys.exit(1)
