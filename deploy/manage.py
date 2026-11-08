#!/usr/bin/env python3
"""Manage one installed Vao Push instance without regenerating its identity."""
import argparse
import fcntl
from contextlib import contextmanager
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
                if response.status==200:
                    data=json.load(response).get('data',{})
                    expected=json.loads((root/'current/bundle.json').read_text())['version']
                    if data.get('status')=='ok' and (data.get('server_version')==expected or expected=='1.0.0' and data.get('server_version') is None):return True
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
    path.chmod(owner.st_mode & 0o777)
    os.chown(path,owner.st_uid,owner.st_gid)

@contextmanager
def upgrade_lock(root):
    with (root/'run/upgrade.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise RuntimeError('Another upgrade is running')
        try:yield
        finally:fcntl.flock(lock,fcntl.LOCK_UN)

def upgrade(root,bundle):
    with upgrade_lock(root):return upgrade_locked(root,bundle)

def upgrade_locked(root,bundle):
    manifest=validate_bundle(bundle)
    import re
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}',manifest['version']):raise RuntimeError('Invalid release version')
    target=root/'releases'/manifest['version']
    if target.exists():
        # A maintenance rebuild keeps the public version while preserving the
        # previous immutable program directory for rollback.
        identity=hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest()[:16]
        current=(root/'current').resolve()
        if current.is_dir():
            installed=validate_bundle(current)
            if installed==manifest:
                print('This exact release is already installed. Configuration and data were kept.')
                return
        target=root/'releases'/(manifest['version']+'-'+identity)
        if target.exists():raise RuntimeError('This release content directory already exists; files were kept')
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
    for directory in [target/'bin',target/'web']:
        if directory.exists():
            directory.chmod(0o755)
            for path in directory.rglob('*'):
                path.chmod(0o755 if path.is_dir() or path==target/'bin/vao-push' else 0o644)
    try:
        identity_target=prepare_packaged_identity(root,target,manifest,config)
        if identity_target:
            temporary=config_path.with_name(config_path.name+'.next')
            temporary.write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
            temporary.chmod(config_owner.st_mode & 0o777)
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
        if manifest.get('web_updates'):
            configure_web_updates(root,target)
            config_changed=True
        run(['systemctl','start',service(root)+'.service'])
        if not healthy(root):raise RuntimeError('New version did not pass health check')
    except BaseException:
        if (root/'current').is_symlink() and (root/'current').resolve()==target.resolve():
            (root/'current.previous').symlink_to(previous);os.replace(root/'current.previous',root/'current')
        elif not (root/'current').exists():
            (root/'current').symlink_to(previous)
        restore_config(config_path,original_config,config_owner)
        if identity_target:
            identity_target.unlink(missing_ok=True)
        run(['systemctl','restart',service(root)+'.service'])
        if not healthy(root):raise RuntimeError('Previous program selected but recovery health check failed; inspect the service before retrying')
        print('The previous program was restored and passed its health check. Database migrations are not automatically reversed.')
        raise
    metadata_path=root/'run/installation.json';metadata_owner=metadata_path.stat()
    metadata=load(root);metadata['version']=manifest['version']
    metadata_path.write_text(json.dumps(metadata,indent=2)+'\n');metadata_path.chmod(metadata_owner.st_mode&0o777)
    print('Upgraded to '+manifest['version']+'. Existing ports, password, server identity, data, and encryption key were kept.')

def configure_web_updates(root,bundle):
    import importlib.util
    spec=importlib.util.spec_from_file_location('vao_update_setup',bundle/'install-update-agent.py')
    setup=importlib.util.module_from_spec(spec);spec.loader.exec_module(setup)
    return setup.configure(root,bundle,activate=True)

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
