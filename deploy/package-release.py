#!/usr/bin/env python3
"""Package a prebuilt server and Web UI. Does not upload or publish anything."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import tarfile


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version',required=True)
    parser.add_argument('--arch',choices=['amd64','arm64'],required=True)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--web',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--candidate',action='store_true')
    parser.add_argument('--apns-file',type=Path)
    args=parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,79}',args.version):parser.error('Invalid version')
    repository=Path(__file__).resolve().parent.parent
    if not args.candidate and (not (repository/'LICENSE').is_file() or not (repository/'THIRD_PARTY_NOTICES.txt').is_file() or not args.apns_file):parser.error('Official packaging requires an approved LICENSE and a production APNs identity file. Use --candidate for internal validation.')
    identity=None
    if args.apns_file:
        identity=json.loads(args.apns_file.read_text())
        if identity.get('topic')!='app.vaovao.push' or identity.get('environment')!='production':parser.error('The official identity must declare the app.vaovao.push production environment')
        if not all(re.fullmatch(r'[A-Z0-9]{10}',identity.get(k,'')) for k in ['key_id','team_id']) or 'PRIVATE KEY' not in identity.get('private_key',''):parser.error('Invalid APNs identity file')
    args.out.mkdir(parents=True,exist_ok=True)
    name='vao-push-'+args.version+'-linux-'+args.arch
    stage=args.out/name
    if stage.exists():parser.error('Output already exists; keeping the previous artifact')
    stage.mkdir(mode=0o700)
    (stage/'bin').mkdir(mode=0o755)
    (stage/'bin').chmod(0o755)
    shutil.copyfile(args.binary,stage/'bin/vao-push');(stage/'bin/vao-push').chmod(0o755)
    if not (args.web/'index.html').is_file():parser.error('Web build is missing index.html')
    shutil.copytree(args.web,stage/'web')
    # The packaging host may use umask 077. Public program and Web assets
    # must remain traversable/readable by the unprivileged service account.
    for path in [stage/'web', *sorted((stage/'web').rglob('*'))]:
        path.chmod(0o755 if path.is_dir() else 0o644)
    for source in ['install.py','manage.py','install.sh']:
        shutil.copyfile(repository/'deploy'/source,stage/source);(stage/source).chmod(0o755)
    if identity:
        (stage/'private').mkdir(mode=0o700)
        (stage/'private/apns.json').write_text(json.dumps({k:identity[k] for k in ['key_id','team_id','topic','private_key']}))
        (stage/'private/apns.json').chmod(0o600)
    for source in ['LICENSE','THIRD_PARTY.md','THIRD_PARTY_NOTICES.txt']:
        if (repository/source).is_file():shutil.copyfile(repository/source,stage/source)
    readme=repository/'deploy/PUBLIC-INSTALL.md'
    if readme.is_file():shutil.copyfile(readme,stage/'README.md')
    files={str(path.relative_to(stage)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(stage.rglob('*')) if path.is_file()}
    (stage/'bundle.json').write_text(json.dumps({'version':args.version,'platform':'linux','arch':args.arch,'candidate':args.candidate,'official_push_identity':identity is not None,'files':files},indent=2)+'\n')
    archive=args.out/(name+'.tar.gz')
    with tarfile.open(archive,'w:gz') as tar:
        for path in sorted(stage.rglob('*')):
            tar.add(path,arcname=str(path.relative_to(stage)),recursive=False)
    digest=hashlib.sha256(archive.read_bytes()).hexdigest()
    (args.out/(archive.name+'.sha256')).write_text(digest+'  '+archive.name+'\n')
    print(archive);print('SHA256 '+digest)

if __name__=='__main__':main()
