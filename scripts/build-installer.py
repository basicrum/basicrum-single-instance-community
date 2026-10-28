#!/usr/bin/env python3
"""Build the standalone installer without including any installation state."""

import argparse
import hashlib
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
# Explicit allowlist: never glob the checkout, which may contain live secrets.
BUNDLE_FILES = (
    "start.sh",
    "lib/preflight.sh",
    "README.md",
    "docker-compose.yml",
    "compose.https.yml",
    "clickhouse-config/system-logs.xml",
)


def build(output: Path) -> None:
    start_file = ROOT / "start.sh"
    if start_file.is_symlink() or not start_file.is_file():
        raise ValueError(f"Bundle input must be a regular file: {start_file}")
    start_source = start_file.read_text()
    versions = re.findall(r'^DEFAULT_BASICRUM_VERSION="([^"]+)"$', start_source, re.MULTILINE)
    stable_tag = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    if len(versions) != 1 or not re.fullmatch(stable_tag, versions[0]):
        raise ValueError("start.sh must declare one stable DEFAULT_BASICRUM_VERSION")
    embedded_files = []
    for name in BUNDLE_FILES:
        source = ROOT / name
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Bundle input must be a regular file: {source}")
        contents = source.read_bytes()
        text = contents.decode("utf-8")
        if "\0" in text or (text and not text.endswith("\n")):
            raise ValueError(f"Bundle input must be text ending in a newline: {source}")
        delimiter = "BASICRUM_FILE_" + re.sub(r"[^A-Z0-9]", "_", name.upper())
        # A future source edit must never accidentally close its own heredoc.
        while delimiter in text.splitlines():
            delimiter += "_"
        checksum = hashlib.sha256(contents).hexdigest()
        embedded_files.append(
            f"  # Begin embedded file: {name}\n"
            f"  cat > \"$work_dir/bundle/{name}\" <<'{delimiter}'\n"
            f"{text}{delimiter}\n"
            f"  # End embedded file: {name}\n"
            f"  verify_file '{name}' '{checksum}'\n"
        )
    template = (ROOT / "installer/bootstrap.sh").read_text()
    assert template.count("@BASICRUM_FILES@") == 1
    assert template.count("@BASICRUM_VERSION@") == 1
    script = template.replace("@BASICRUM_VERSION@", versions[0])
    script = script.replace("@BASICRUM_FILES@", "\n".join(embedded_files))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(script)
    output.chmod(0o755)
    installer_sha = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_name(output.name + ".sha256").write_text(f"{installer_sha}  {output.name}\n")
    print(f"Built {output} ({output.stat().st_size:,} bytes)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/install.sh")
    build(parser.parse_args().output.resolve())
