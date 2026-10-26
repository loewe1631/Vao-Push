#!/usr/bin/env python3
"""Manage one installed Vao Push instance without regenerating its identity."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request
import uuid


def run(args,**kwargs):return subprocess.run(args,check=True,**kwargs)
def load(root):return json.loads((root/'run/installation.json').read_text())
def service(root):return load(root)['service_name']
def database(root):return service(root)+'-postgres'
def backup(root):
    destination=root/'backups'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:6]);destination.mkdir(mode=0o700)
    partial=destination/'database.dump.partial'
    try:
        with partial.open('wb') as output:run(['docker','exec',database(root),'pg_dump','-U','vaopush','-Fc','vaopush'],stdout=output)
        if partial.stat().st_size<1:raise RuntimeError('Empty database backup')
        partial.rename(destination/'database.dump')
        shutil.copytree(root/'run',destination/'run',ignore=shutil.ignore_patterns('*.log'))
        for path in destination.rglob('*'):
            if path.is_file():path.chmod(0o600)
        print('Backup: '+str(destination))
        return destination
    except BaseException:
        print('Backup did not finish; no services were changed.')
        raise

def healthy(root):
    config=json.loads((root/'run/config.json').read_text())
    port=config.get('web_listen',config['listen']).rsplit(':',1)[1]
    for _ in range(20):
        try:
            with urllib.request.urlopen('http://127.0.0.1:'+port+'/healthz',timeout=2) as response:
                if response.status==200:return True
        except Exception:time.sleep(1)
    return False

def validate_bundle(bundle):
    manifest=json.loads((bundle/'bundle.json').read_text())
    for name,digest in manifest['files'].items():
        path=bundle/name
        if Path(name).is_absolute() or '..' in Path(name).parts or path.is_symlink():raise RuntimeError('Invalid bundle path')
        if hashlib.sha256(path.read_bytes()).hexdigest()!=digest:raise RuntimeError('Bundle checksum verification failed')
    return manifest

def prepare_packaged_identity(root,bundle,manifest,config):
    """Stage a bundled APNs identity when an existing install has none.

    An operator-configured identity always wins. An unreferenced identity file
    is treated as ambiguous and is never overwritten during an upgrade.
    """
    if not manifest.get('official_push_identity') or config.get('apns_identity_file'):
        return None
    source=bundle/'private/apns.json'
    if not source.is_file() or source.is_symlink():
        raise RuntimeError('Bundle APNs identity is missing or invalid')
    target=root/'run/apns.json'
    if target.exists() or target.is_symlink():
        raise RuntimeError('An unreferenced APNs identity already exists; refusing to overwrite it')
    shutil.copyfile(source,target)
    target.chmod(0o600)
    owner=(root/'run/config.json').stat()
    os.chown(target,owner.st_uid,owner.st_gid)
    config['apns_identity_file']=str(target)
    return target

def restore_config(path,raw,owner):
    path.write_bytes(raw)
    path.chmod(0o600)
    os.chown(path,owner.st_uid,owner.st_gid)

def upgrade(root,bundle):
    manifest=validate_bundle(bundle)
    import re
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}',manifest['version']):raise RuntimeError('Invalid release version')
    target=root/'releases'/manifest['version']
    if target.exists():raise RuntimeError('This release directory already exists; files were kept')
    backup(root)
    config_path=root/'run/config.json'
    original_config=config_path.read_bytes()
    config_owner=config_path.stat()
    config=json.loads(original_config)
    identity_target=None
    config_changed=False
    shutil.copytree(bundle,target)
    target.chmod(0o755)
    (target/'bin/vao-push').chmod(0o755)
    try:
        identity_target=prepare_packaged_identity(root,target,manifest,config)
        if identity_target:
            temporary=config_path.with_name(config_path.name+'.next')
            temporary.write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
            temporary.chmod(0o600)
            os.chown(temporary,config_owner.st_uid,config_owner.st_gid)
            os.replace(temporary,config_path)
            config_changed=True
    except BaseException:
        if identity_target:
            identity_target.unlink(missing_ok=True)
        restore_config(config_path,original_config,config_owner)
        shutil.rmtree(target,ignore_errors=True)
        raise
    previous=(root/'current').resolve()
    try:
        run(['systemctl','stop',service(root)+'.service'])
        next_link=root/'current.next';next_link.symlink_to(target);os.replace(next_link,root/'current')
        run(['systemctl','start',service(root)+'.service'])
        if not healthy(root):raise RuntimeError('New version did not pass health check')
    except BaseException:
        if (root/'current').is_symlink() and (root/'current').resolve()==target.resolve():
            (root/'current.previous').symlink_to(previous);os.replace(root/'current.previous',root/'current')
        elif not (root/'current').exists():
            (root/'current').symlink_to(previous)
        if config_changed:
            restore_config(config_path,original_config,config_owner)
            identity_target.unlink(missing_ok=True)
        run(['systemctl','restart',service(root)+'.service'])
        print('The previous program was restored. Database backups are available; database migrations are not automatically reversed.')
        raise
    metadata=load(root);metadata['version']=manifest['version']
    (root/'run/installation.json').write_text(json.dumps(metadata,indent=2)+'\n');(root/'run/installation.json').chmod(0o600)
    print('Upgraded to '+manifest['version']+'. Existing ports, password, server identity, data, and encryption key were kept.')

def restore_check(root,source):
    name='vao_restore_check_'+uuid.uuid4().hex
    run(['docker','exec',database(root),'createdb','-U','vaopush',name])
    try:
        with source.open('rb') as stream:run(['docker','exec','-i',database(root),'pg_restore','-U','vaopush','-d',name,'--no-owner'],stdin=stream)
        run(['docker','exec',database(root),'psql','-U','vaopush','-d',name,'-Atc','SELECT count(*) FROM messages'])
    finally:run(['docker','exec',database(root),'dropdb','-U','vaopush','--if-exists',name])

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,default=Path('/opt/vao-push'))
    parser.add_argument('command',choices=['start','stop','restart','status','logs','backup','restore-check','upgrade'])
    parser.add_argument('path',nargs='?',type=Path)
    args=parser.parse_args();root=args.root.absolute()
    if args.command in ['start','stop','restart','status']:run(['systemctl',args.command,service(root)+'.service'])
    elif args.command=='logs':run(['journalctl','-u',service(root)+'.service','-n','100','--no-pager'])
    elif args.command=='backup':backup(root)
    elif args.command=='restore-check':
        if not args.path:parser.error('Pass database.dump')
        restore_check(root,args.path)
    elif args.command=='upgrade':
        if not args.path:parser.error('Pass an extracted release bundle directory')
        upgrade(root,args.path.resolve())

if __name__=='__main__':
    try:main()
    except (RuntimeError,ValueError,OSError,subprocess.CalledProcessError,KeyError) as error:
        print('Operation incomplete: '+str(error));raise SystemExit(1)
