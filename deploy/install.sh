#!/usr/bin/env bash
set -euo pipefail
umask 077
installer_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
  echo '需要 Python 3。请安装：sudo apt-get install python3 / Python 3 is required: sudo apt-get install python3' >&2
  exit 1
fi
if [[ -f "$installer_dir/bundle.json" ]]; then
  exec python3 "$installer_dir/install.py" "$@"
fi
case "$(uname -m)" in
  x86_64) release_arch=amd64 ;;
  aarch64|arm64) release_arch=arm64 ;;
  *) echo '不支持的架构 / Unsupported architecture' >&2; exit 1 ;;
esac
[[ "$(uname -s)" == Linux ]] || { echo '仅支持 Linux / Linux is required' >&2; exit 1; }
release_version=${VAO_VERSION:-1.0.0}
[[ "$release_version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || exit 1
release_base=${VAO_RELEASE_BASE:-https://github.com/loewe1631/Vao-Push/releases/download/v$release_version}
release_file=vao-push-$release_version-linux-$release_arch.tar.gz
release_temp=$(mktemp -d)
trap 'rm -rf -- "$release_temp"' EXIT
curl --fail --location --proto '=https' --max-time 180 "$release_base/$release_file" -o "$release_temp/$release_file"
curl --fail --location --proto '=https' --max-time 30 "$release_base/$release_file.sha256" -o "$release_temp/checksum"
python3 - "$release_temp" "$release_file" <<'PY'
import hashlib, pathlib, re, sys, tarfile
root=pathlib.Path(sys.argv[1]);name=sys.argv[2]
expected=(root/'checksum').read_text().split()[0]
if not re.fullmatch(r'[a-fA-F0-9]{64}',expected) or hashlib.sha256((root/name).read_bytes()).hexdigest()!=expected.lower():raise SystemExit('SHA256 verification failed')
with tarfile.open(root/name) as tar:
 for member in tar.getmembers():
  path=pathlib.PurePosixPath(member.name)
  if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):raise SystemExit('Unsafe archive path')
 tar.extractall(root/'bundle')
PY
if [[ -t 0 ]] || [[ " $* " == *' --non-interactive '* ]]; then
  python3 "$release_temp/bundle/install.py" "$@"
else
  python3 "$release_temp/bundle/install.py" "$@" </dev/tty
fi
