# Maintaining the Basicrum installer

## Building the downloadable installer

Maintainers need Python 3 to build; end users do not:

```bash
python3 scripts/build-installer.py
bash scripts/validate-installer.sh
bash dist/install.sh --help
```

The builder packages only `start.sh`, `lib/preflight.sh`, `README.md`, both Compose files, and
`clickhouse-config/system-logs.xml`. It never packages `.env`, installation
data, generated Traefik configuration, or certificates. The output
is `dist/install.sh` plus `dist/install.sh.sha256`; building does not upload
anything. Rebuild whenever the bundled source files change.

The script includes a labeled, readable copy of every packaged file in quoted
shell heredocs. Open `dist/install.sh` to inspect the full setup scripts,
Compose configuration, and other files directly. Nothing is compressed or
encoded, and there is no second download URL or branch that can drift. Quoted
heredocs preserve each file's source literally, without evaluating its shell
variables or commands while writing it.

Each file's SHA-256 is checked in a temporary directory before the installation
directory is updated. Installation starts only after Bash has parsed the
complete installer function. The embedded checksums detect accidental file
corruption; trust in the installer itself comes from its HTTPS delivery source.

To try the actual curl flow locally, serve `dist/` in one terminal:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory dist
```

Then, with Docker running, use a separate destination in another terminal:

```bash
curl -fsSL http://127.0.0.1:8765/install.sh | bash -s -- \
  --install-dir "$HOME/basicrum-preview" \
  --domain localhost --tls none --http-port 8080 --no-start --yes
```

This writes and validates the preview configuration without starting services.
Omit `--no-start` on a later run of the same installer command to start it.

## CI and installer releases

`.github/workflows/ci.yml` runs on branch pushes and pull requests. It calls
`scripts/validate-installer.sh` to check Bash syntax, build the installer, run
the tests (including real Compose rendering and a local curl pipeline), and
verify that rebuilding produces identical files and a matching SHA-256.
Validation needs Python 3, Bash, Docker with Compose, curl and OpenSSL. It does
not start the application containers.

`.github/workflows/release.yml` is a manually triggered **Prepare installer
release** workflow:

For an application image update, publish the same new tag in all three
community image repositories and change `DEFAULT_BASICRUM_VERSION` in
`start.sh` before preparing the installer release. The builder embeds that
tag in `install.sh`; the release workflow pulls and smoke tests it. Installer
release tags and application image tags are separate version numbers.

1. Push a stable version tag such as `v1.0.0` pointing to a commit in the
   default branch's history. That commit must include these CI scripts.
2. Open **Actions → Prepare installer release → Run workflow**, select the
   default branch and enter the tag. Branches, nonexistent tags and prerelease
   version names are rejected.
3. The workflow checks out the tag's exact commit, runs validation, then uses
   real Docker to install into a temporary directory. It requires all six
   services to be healthy and the login page to return HTTP 200. It reruns the
   same installer and verifies that `.env`, the Traefik configuration and the
   named volumes are preserved.
4. After successful cleanup, the tested `install.sh` and `install.sh.sha256`
   are transferred to a separate job. That job verifies the checksum and that
   the tag still points to the tested commit, then creates a **draft release**
   containing those exact files. An existing release is not overwritten.
5. Review the draft in **Releases**, then publish it when ready. Creating a
   draft does not update the public installer download.

Only the draft-creation job has repository write permission; it does not
execute code from the checkout. Pull requests and pushes run validation only.
The release workflow uses disposable Ubuntu 24.04 runners and removes unused
Android, .NET and GHC tooling there to make room for Docker. The installer
still enforces its normal CPU, memory and 20 GiB free Docker-storage minimums.
Image pull failures or insufficient runner resources fail the release.

The real Docker check can also be run locally after building:

```bash
python3 scripts/smoke-installer.py
```

It uses a randomly named Compose project and unused loopback ports, and cleans
up that project's containers, networks, volumes and temporary directory on
success or failure. Existing installations are not used. Failure diagnostics
redact the generated secrets. `--no-pull` uses cached images for local runs;
the release workflow always pulls. This check exercises HTTP mode; it does
not test public DNS, Let's Encrypt issuance or browser interactions.

The download command in the installation section above resolves to the latest
published stable release. Current assets are listed on the
[releases page](https://github.com/basicrum/basicrum-single-instance-community/releases).
