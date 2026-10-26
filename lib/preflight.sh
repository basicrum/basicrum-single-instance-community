#!/usr/bin/env bash
# Shared by start.sh and the downloadable installer. Bash 3.2 compatible.
# This file defines functions only; sourcing it never changes the installation.

PREFLIGHT_MIN_DOCKER=20.10.10
PREFLIGHT_MIN_API=1.40
PREFLIGHT_MIN_COMPOSE=2.24.0
PREFLIGHT_MIN_DISK_KIB=20971520 # 20 GiB for Docker's data filesystem

preflight_die() { printf 'Preflight failed: %s\n' "$*" >&2; exit 1; }
preflight_note() { printf 'Preflight: %s\n' "$*"; }

preflight_version_ge() {
  # Compare numeric releases; allow distro/build suffixes, but not prereleases.
  LC_ALL=C awk -v actual="$1" -v minimum="$2" 'BEGIN {
    sub(/^v/, "", actual)
    if (actual !~ /^[0-9]+\.[0-9]+(\.[0-9]+)?([-+][A-Za-z0-9._~+-]+)?$/) exit 1
    if (tolower(actual) ~ /-(alpha|beta|rc|dev|pre|nightly)/) exit 1
    sub(/[-+].*$/, "", actual)
    split(actual, a, "."); split(minimum, b, ".")
    for (i = 1; i <= 3; i++) {
      if (a[i] + 0 > b[i] + 0) exit 0
      if (a[i] + 0 < b[i] + 0) exit 1
    }
    exit 0
  }'
}

preflight_require_version() {
  preflight_version_ge "$2" "$3" || preflight_die "$1 '${2:-unknown}' is unsupported; stable version $3 or newer is required."
}

preflight_disk_kib() {
  local available
  available="$(LC_ALL=C df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }')" \
    || preflight_die "cannot inspect free disk space at $1"
  case "$available" in ''|*[!0-9]*) preflight_die "cannot determine free disk space at $1" ;; esac
  printf '%s' "$available"
}

preflight_check() {
  local target="$1" tool endpoint versions engine api client info os arch cpus memory data_root operating_system available
  for tool in docker openssl curl awk grep sed tr sort head tail mktemp chmod cp mv rm mkdir df dirname cat uname date sleep install; do
    command -v "$tool" >/dev/null 2>&1 || preflight_die "$tool is required; install it and run setup again."
  done
  preflight_require_version Bash "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}" 3.2.0

  case "$(uname -s)" in
    Linux)
      for tool in ss getent; do
        command -v "$tool" >/dev/null 2>&1 || preflight_die "$tool is required on Linux (install iproute2 and libc utilities)."
      done ;;
    Darwin)
      for tool in lsof dscacheutil; do
        command -v "$tool" >/dev/null 2>&1 || preflight_die "$tool is required on macOS."
      done ;;
    *) preflight_die 'use Linux, or macOS with Docker Desktop running Linux containers.' ;;
  esac

  # Bind mounts and localhost checks require a local daemon. DOCKER_CONTEXT
  # takes precedence over DOCKER_HOST, matching Docker's own selection rules.
  if [ -n "${DOCKER_CONTEXT:-}" ]; then
    endpoint="$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" \
      || preflight_die 'cannot inspect the selected Docker context.'
  elif [ -n "${DOCKER_HOST:-}" ]; then
    endpoint="$DOCKER_HOST"
  else
    endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)" \
      || preflight_die 'cannot inspect the selected Docker context.'
  fi
  case "$endpoint" in unix:///*) ;; *) preflight_die 'a local Docker Unix socket is required; remote Docker contexts are unsupported by this single-server installer.' ;; esac

  info="$(docker info --format '{{.OSType}}|{{.Architecture}}|{{.NCPU}}|{{.MemTotal}}|{{.DockerRootDir}}|{{.OperatingSystem}}' 2>/dev/null)" \
    || preflight_die 'Docker is not reachable; start Docker and check your access to its socket.'
  versions="$(docker version --format '{{.Server.Version}}|{{.Server.APIVersion}}|{{.Client.Version}}' 2>/dev/null)" \
    || preflight_die 'cannot read Docker Engine and API versions.'
  IFS='|' read -r engine api client <<< "$versions"
  preflight_require_version 'Docker Engine' "$engine" "$PREFLIGHT_MIN_DOCKER"
  preflight_require_version 'Docker CLI' "$client" "$PREFLIGHT_MIN_DOCKER"
  preflight_require_version 'Docker server API' "$api" "$PREFLIGHT_MIN_API"
  if [ -n "${DOCKER_API_VERSION:-}" ]; then
    preflight_require_version DOCKER_API_VERSION "$DOCKER_API_VERSION" "$PREFLIGHT_MIN_API"
  fi
  PREFLIGHT_COMPOSE_VERSION="$(docker compose version --short 2>/dev/null)" \
    || preflight_die 'the Docker Compose plugin is required (docker compose).'
  preflight_require_version 'Docker Compose' "$PREFLIGHT_COMPOSE_VERSION" "$PREFLIGHT_MIN_COMPOSE"

  IFS='|' read -r os arch cpus memory data_root operating_system <<< "$info"
  [ "$os" = linux ] || preflight_die 'Docker must be running Linux containers.'
  case "$arch" in
    x86_64|amd64) ;;
    aarch64|arm64) preflight_note 'ARM64 daemon: startup will verify AMD64 emulation using the backend image.' ;;
    *) preflight_die "unsupported Docker architecture '${arch:-unknown}'; use AMD64 or ARM64 with AMD64 emulation." ;;
  esac
  case "$cpus:$memory" in *[!0-9:]*|:*|*:) preflight_die 'cannot determine Docker CPU/RAM capacity.' ;; esac
  [ "$cpus" -ge 2 ] || preflight_die "Docker has $cpus CPU(s); allocate at least 2."
  # A nominal 4 GiB Linux host reports less after kernel reservations.
  [ "$memory" -ge 3758096384 ] || preflight_die 'Docker needs at least 4 GiB of allocated RAM (3.5 GiB reported after system reservations).'

  while [ ! -d "$target" ]; do target="$(dirname "$target")"; done
  [ -w "$target" ] || preflight_die "installation directory is not writable: $target"
  available="$(preflight_disk_kib "$target")" || exit 1
  [ "$available" -ge 102400 ] || preflight_die 'at least 100 MiB of free space is required for installation files.'
  if [ "$(uname -s)" = Linux ] && [ "$operating_system" != 'Docker Desktop' ] && [ -d "$data_root" ]; then
    available="$(preflight_disk_kib "$data_root")" || exit 1
    [ "$available" -ge "$PREFLIGHT_MIN_DISK_KIB" ] || preflight_die 'Docker data storage needs at least 20 GiB free.'
  fi
  preflight_note "Docker $engine (API $api), Compose $PREFLIGHT_COMPOSE_VERSION, CPU/RAM and installation storage checks passed."
}

preflight_bindings_overlap() {
  local first="${1%:*}" second="${2%:*}"
  [ "${1##*:}" = "${2##*:}" ] || return 1
  case "$first" in '*'|0.0.0.0|'::'|'[::]') return 0 ;; esac
  case "$second" in '*'|0.0.0.0|'::'|'[::]') return 0 ;; esac
  first="${first#[}"; first="${first%]}"
  second="${second#[}"; second="${second%]}"
  [ "$first" = "$second" ]
}

preflight_network() {
  local domain="$1" tls="$2" project="$3" directory="$4"
  shift 4
  local binding port previous requested='' ids id record owner workdir ports foreign='' own='' listeners address
  for binding in "$@"; do
    port="${binding##*:}"
    case "$port" in ''|*[!0-9]*) preflight_die "invalid published port: $binding" ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || preflight_die "invalid published port: $binding"
    for previous in $requested; do
      if preflight_bindings_overlap "$binding" "$previous"; then
        preflight_die "configured port bindings overlap: $binding and $previous; choose distinct ports."
      fi
    done
    requested="$requested $binding"
  done

  # Check published ports even on hosts where Docker uses NAT without a
  # listening docker-proxy process. Only this exact installation is exempt.
  ids="$(docker ps -aq 2>/dev/null)" || preflight_die 'cannot inspect Docker containers.'
  for id in $ids; do
    record="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{if .State.Running}}{{range $port, $bindings := .NetworkSettings.Ports}}{{if eq (index (split $port "/") 1) "tcp"}}{{range $bindings}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}{{end}}{{end}}' "$id" 2>/dev/null)" \
      || preflight_die 'cannot inspect Docker port bindings.'
    IFS='|' read -r owner workdir ports <<< "$record"
    if [ "$owner" = "$project" ] && [ "$workdir" = "$directory" ]; then
      own="$own $ports"
    else
      # A second project with the same name would be modified by Compose.
      [ "$owner" != "$project" ] || preflight_die "Compose project '$project' already belongs to another directory: $workdir"
      foreign="$foreign $ports"
    fi
  done
  if [ "$(uname -s)" = Linux ]; then
    listeners="$(ss -H -ltn 2>/dev/null)" || preflight_die 'cannot inspect listening TCP ports with ss.'
    listeners="$(printf '%s\n' "$listeners" | awk '{print $4}')"
  else
    local status=0
    listeners="$(lsof -nP -iTCP -sTCP:LISTEN -Fn 2>/dev/null)" || status=$?
    [ "$status" -le 1 ] || preflight_die 'cannot inspect listening TCP ports with lsof.'
    listeners="$(printf '%s\n' "$listeners" | sed -n 's/^n//p')"
  fi
  for binding in $requested; do
    for address in $foreign; do
      if preflight_bindings_overlap "$binding" "$address"; then
        preflight_die "port $binding is already published by another container; choose another port."
      fi
    done
    for address in $listeners; do
      preflight_bindings_overlap "$binding" "$address" || continue
      local owned=false
      for previous in $own; do
        if preflight_bindings_overlap "$address" "$previous"; then owned=true; break; fi
      done
      [ "$owned" = true ] || preflight_die "port $binding is already listening on this host; choose another port."
    done
  done

  if [ "$tls" = letsencrypt ]; then
    if [ "$(uname -s)" = Linux ]; then
      address="$(getent ahosts "$domain" 2>/dev/null)" || preflight_die "hostname $domain does not resolve; configure DNS before requesting a certificate."
      [ -n "$address" ] || preflight_die "hostname $domain does not resolve."
    else
      address="$(dscacheutil -q host -a name "$domain" 2>/dev/null)" || preflight_die "cannot resolve hostname $domain."
      printf '%s\n' "$address" | grep -Eq '(ip_address|ipv6_address):' || preflight_die "hostname $domain does not resolve; configure DNS before requesting a certificate."
    fi
    preflight_note 'hostname resolves; public routing/firewall and certificate issuance are verified by the public HTTPS check after startup.'
  fi
  preflight_note 'configured TCP ports are available (existing ports of this installation are allowed).'
}

preflight_images() {
  local backend="$1" clickhouse="$2" available
  # These probes use the images just pulled by Compose, expose no ports, mount
  # no installation data, and remove their temporary containers on completion.
  docker run --rm --pull never --platform linux/amd64 --network none --read-only \
    --entrypoint node "$backend" --version >/dev/null \
    || preflight_die 'the AMD64 backend image cannot execute; check CPU architecture/emulation and the selected image tag.'
  available="$(docker run --rm --pull never --network none --read-only --entrypoint /bin/sh "$clickhouse" \
    -c 'clickhouse --version >/dev/null && df -Pk /var/lib/clickhouse | awk "NR == 2 { print \$4 }"')" \
    || preflight_die 'the ClickHouse image cannot execute; check CPU compatibility and the selected image tag.'
  case "$available" in ''|*[!0-9]*) preflight_die 'cannot determine free space in Docker data storage.' ;; esac
  [ "$available" -ge "$PREFLIGHT_MIN_DISK_KIB" ] || preflight_die 'Docker data storage needs at least 20 GiB free; increase Docker Desktop disk capacity or free space.'
  preflight_note 'application image execution and Docker data storage checks passed.'
}

preflight_wait_url() {
  local url="$1" timeout="$2" label="$3" started="$SECONDS" code=''
  shift 3
  while [ "$((SECONDS - started))" -lt "$timeout" ]; do
    code="$(curl --noproxy '*' --connect-timeout 2 --max-time 5 -s -o /dev/null -w '%{http_code}' "$@" "$url" 2>/dev/null)" || code=000
    if [ "$code" = 200 ]; then preflight_note "$label answers HTTP 200."; return 0; fi
    sleep 1
  done
  preflight_die "$label did not become ready within ${timeout}s (last HTTP status: $code). Inspect docker compose ps and docker compose logs traefik."
}
