#!/usr/bin/env bash
# Build with: python3 scripts/build-installer.py
# Every installed file is included below as readable source in a quoted heredoc.
# The complete function (including those files) is parsed before installation
# starts, so a truncated download cannot run a partially received installer.

basicrum_install() (
  set -euo pipefail

  die() { printf 'basicrum: %s\n' "$*" >&2; exit 1; }
  usage() {
    cat <<'HELP'
Basicrum community installer

Usage: curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash
       curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash -s -- [options]

Installs into ~/basicrum by default, then asks for a hostname and TLS mode.
Requires Docker Engine 20.10.10+ (API 1.40+), Compose 2.24+, Bash 3.2+,
OpenSSL, curl, 2 CPUs, and 4 GiB RAM allocated to Docker.

  --install-dir DIR       Where to keep this installation
  --domain NAME           Public hostname (e.g. rum.example.com)
  --tls MODE              cloudflare (Origin CA), letsencrypt, custom, or none
  --email ADDRESS         Contact address for Let's Encrypt
  --cert FILE --key FILE  Certificate and private key for cloudflare or custom TLS
  --public-url URL        Browser-facing URL when using your own reverse proxy
  --http-port PORT        HTTP port (default 80)
  --https-port PORT       HTTPS port (default 443)
  --version TAG           Override this release's application image tag
  --set KEY=VALUE         Additional setting; may be repeated
  --acme-staging          Use Let's Encrypt's staging CA
  --no-start              Write and validate configuration without starting
  --no-pull               Skip pulling container images
  -y, --yes               Never prompt; supply required settings as flags
  -h, --help              Show this help

Re-running the latest installer applies its application image tag and refreshes
the packaged files. Existing settings, secrets, certificates, and Docker
volumes are preserved.
HELP
  }

  bundle_version='@BASICRUM_VERSION@'
  install_dir="${HOME:?HOME must be set}/basicrum"
  original_dir="$PWD"
  start_args=()
  assume_yes=false
  version_requested=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install-dir)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die '--install-dir needs a directory'
        install_dir="$2"; shift 2 ;;
      --install-dir=*)
        install_dir="${1#*=}"; shift ;;
      --cert|--key)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a path"
        cert_path="$2"
        case "$cert_path" in /*) ;; *) cert_path="$original_dir/$cert_path" ;; esac
        start_args+=("$1" "$cert_path"); shift 2 ;;
      --cert=*|--key=*)
        option="${1%%=*}"; cert_path="${1#*=}"
        [ -n "$cert_path" ] || die "$option needs a path"
        case "$cert_path" in /*) ;; *) cert_path="$original_dir/$cert_path" ;; esac
        start_args+=("$option" "$cert_path"); shift ;;
      --version)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die '--version needs a value'
        start_args+=("$1" "$2"); version_requested=true; shift 2 ;;
      --version=*)
        [ -n "${1#*=}" ] || die '--version needs a value'
        start_args+=("$1"); version_requested=true; shift ;;
      --domain|--tls|--email|--public-url|--http-port|--https-port|--set)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"
        start_args+=("$1" "$2"); shift 2 ;;
      --domain=*|--tls=*|--email=*|--public-url=*|--http-port=*|--https-port=*|--set=*|--acme-staging|--no-start|--no-pull)
        start_args+=("$1"); shift ;;
      -y|--yes)
        assume_yes=true; start_args+=("$1"); shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1 (use --help)" ;;
    esac
  done
  [ "$version_requested" = true ] || start_args+=(--version "$bundle_version")
  [ -n "$install_dir" ] || die '--install-dir needs a directory'
  case "$install_dir" in /*) ;; *) install_dir="$original_dir/$install_dir" ;; esac

  # Read answers from the controlling terminal, never from the script stream.
  # --yes works in CI/SSH sessions without a terminal.
  use_tty=false
  if [ "$assume_yes" = false ] && [ -t 1 ]; then
    if { exec 3</dev/tty; } 2>/dev/null; then use_tty=true; fi
  fi

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/basicrum-install.XXXXXX")"
  trap 'rm -rf "$work_dir"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  verify_file() {
    local name="$1" expected_sha="$2" actual_sha output
    if command -v openssl >/dev/null 2>&1; then
      output="$(openssl dgst -sha256 "$work_dir/bundle/$name")"
      actual_sha="${output##* }"
    elif command -v sha256sum >/dev/null 2>&1; then
      output="$(sha256sum "$work_dir/bundle/$name")"
      actual_sha="${output%% *}"
    elif command -v shasum >/dev/null 2>&1; then
      output="$(shasum -a 256 "$work_dir/bundle/$name")"
      actual_sha="${output%% *}"
    else
      die 'a SHA-256 checker is required to verify the installer (openssl, sha256sum, or shasum); other requirements cannot be checked until one is installed'
    fi
    [ "$actual_sha" = "$expected_sha" ] || die "$name failed its checksum; download the installer again"
  }
  mkdir -p "$work_dir/bundle/clickhouse-config" "$work_dir/bundle/lib"

  # Quoted delimiters keep shell variables and commands inside the files literal.
@BASICRUM_FILES@

  # Validate the host before updating any installed files or existing settings.
  . "$work_dir/bundle/lib/preflight.sh"
  preflight_check "$install_dir"

  # Only update directories previously created by this installer. This avoids
  # replacing unrelated files or a developer's source checkout by accident.
  marker='.basicrum-community-install'
  if [ -e "$install_dir" ] || [ -L "$install_dir" ]; then
    [ -d "$install_dir" ] && [ ! -L "$install_dir" ] || die "$install_dir must be a regular directory"
    if [ -n "$(ls -A "$install_dir")" ]; then
      [ -f "$install_dir/$marker" ] && [ ! -L "$install_dir/$marker" ] \
        && [ "$(cat "$install_dir/$marker")" = 'basicrum-community-v1' ] \
        || die "$install_dir is not an installer-managed directory; choose an empty --install-dir"
    fi
  fi

  # Refuse symlinks in managed paths before copying anything into the install.
  for entry in start.sh lib lib/preflight.sh README.md docker-compose.yml compose.https.yml clickhouse-config clickhouse-config/system-logs.xml .env traefik traefik/dynamic traefik/ssl traefik/traefik.yml traefik/dynamic/tls.yml traefik/ssl/cert.pem traefik/ssl/key.pem; do
    [ ! -L "$install_dir/$entry" ] || die "refusing to replace or write through symlink: $install_dir/$entry"
  done
  mkdir -p "$install_dir/clickhouse-config" "$install_dir/lib"
  for entry in start.sh lib/preflight.sh README.md docker-compose.yml compose.https.yml clickhouse-config/system-logs.xml; do
    cp "$work_dir/bundle/$entry" "$install_dir/$entry"
  done
  chmod 755 "$install_dir/start.sh"
  printf '%s\n' 'basicrum-community-v1' > "$install_dir/$marker"

  printf '\nPreparing Basicrum in %s\n\n' "$install_dir"
  # Keep the caller's directory for relative certificate paths entered at
  # prompts; start.sh records it before changing to its own directory. The
  # guarded array expansion also works with empty arrays on Bash 3.2.
  if [ "$use_tty" = true ]; then
    bash "$install_dir/start.sh" ${start_args[@]+"${start_args[@]}"} <&3
  else
    bash "$install_dir/start.sh" ${start_args[@]+"${start_args[@]}"} </dev/null
  fi
  printf '\nTo start or update this installation later, run:\n  '
  printf 'curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash'
  if [ "$install_dir" != "${HOME:?HOME must be set}/basicrum" ]; then
    printf ' -s -- --install-dir %q' "$install_dir"
  fi
  printf '\n'
)

basicrum_install "$@"
