#!/usr/bin/env bash
# The same checks run locally, on pull requests, and before preparing releases.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for command in python3 bash docker curl openssl cmp; do
  command -v "$command" >/dev/null || { printf 'Missing validation dependency: %s\n' "$command" >&2; exit 1; }
done
# Make the real Compose and curl tests mandatory rather than silently skipped.
docker compose version >/dev/null
export PYTHONDONTWRITEBYTECODE=1

bash -n start.sh
bash -n lib/preflight.sh
bash -n installer/bootstrap.sh
bash -n scripts/validate-installer.sh
python3 scripts/build-installer.py
bash -n dist/install.sh
python3 -m unittest discover -s tests -v

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/basicrum-validate.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
python3 scripts/build-installer.py --output "$work_dir/install.sh"
cmp dist/install.sh "$work_dir/install.sh"
cmp dist/install.sh.sha256 "$work_dir/install.sh.sha256"
python3 - <<'PY'
from pathlib import Path
import hashlib

installer = Path('dist/install.sh')
expected = f'{hashlib.sha256(installer.read_bytes()).hexdigest()}  install.sh\n'
assert installer.with_suffix('.sh.sha256').read_text() == expected, 'Installer checksum mismatch'
print('Installer validation passed; build is reproducible and checksum matches.')
PY
