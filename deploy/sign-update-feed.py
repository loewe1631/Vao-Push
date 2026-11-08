#!/usr/bin/env python3
"""Sign a reviewed update manifest with an offline Ed25519 key; never uploads."""
import argparse,base64,json,subprocess,tempfile
from pathlib import Path

def main():
 p=argparse.ArgumentParser();p.add_argument('--manifest',type=Path,required=True);p.add_argument('--private-key',type=Path,required=True);p.add_argument('--out',type=Path,required=True);a=p.parse_args()
 d=json.loads(a.manifest.read_text());assert d['schema_version']==1 and isinstance(d['releases'],list)
 raw=json.dumps(d,sort_keys=True,separators=(',',':')).encode()
 with tempfile.TemporaryDirectory() as temp:
  temp=Path(temp);(temp/'manifest').write_bytes(raw)
  subprocess.run(['openssl','pkeyutl','-sign','-inkey',str(a.private_key),'-rawin','-in',str(temp/'manifest'),'-out',str(temp/'signature')],check=True)
  result={'manifest':base64.b64encode(raw).decode(),'signature':base64.b64encode((temp/'signature').read_bytes()).decode()}
  with a.out.open('x') as f:json.dump(result,f)
 print('Signed release manifest written. Private key was not included.')
if __name__=='__main__':main()
