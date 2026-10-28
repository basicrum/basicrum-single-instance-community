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

preflight_check() {
  local target="$1" quiet="${2:-}" tool missing='' os_name='' endpoint='' info='' versions=''
  local engine='' api='' client='' compose='' os='' arch='' cpus='' memory='' data_root='' operating_system='' available=''
  local need_count=0 item context_ok=false daemon_ok=false output_fd=1
  local -a ready=() needs=() later=()

  # Collect independent results so customers can fix several requirements at
  # once. Checks that depend on Docker are explicitly marked as deferred.
  if preflight_version_ge "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}" 3.2.0; then
    ready+=("Bash ${BASH_VERSION} (3.2+ required)")
  else
    needs+=("Bash ${BASH_VERSION}: install Bash 3.2 or newer")
    need_count=$((need_count + 1))
  fi
  for tool in openssl curl; do
    if command -v "$tool" >/dev/null 2>&1; then
      ready+=("$tool")
    else
      needs+=("$tool: install it")
      need_count=$((need_count + 1))
    fi
  done
  for tool in awk grep sed tr sort head tail mktemp chmod cp mv rm mkdir df dirname cat uname date sleep install; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -z "$missing" ]; then
    ready+=("standard system utilities")
  else
    needs+=("standard system utilities: install$missing")
    need_count=$((need_count + 1))
  fi

  if command -v uname >/dev/null 2>&1; then os_name="$(uname -s 2>/dev/null || true)"; fi
  case "$os_name" in
    Linux)
      missing=''
      for tool in ss getent; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
      if [ -z "$missing" ]; then ready+=("Linux network tools (ss, getent)")
      else needs+=("Linux network tools:$missing (install iproute2 and libc utilities)"); need_count=$((need_count + 1)); fi ;;
    Darwin)
      missing=''
      for tool in lsof dscacheutil; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
      if [ -z "$missing" ]; then ready+=("macOS network tools (lsof, dscacheutil)")
      else needs+=("macOS network tools:$missing"); need_count=$((need_count + 1)); fi ;;
    *) needs+=("Operating system: use Linux or macOS with Docker Desktop"); need_count=$((need_count + 1)) ;;
  esac

  if command -v docker >/dev/null 2>&1; then
    client="$(docker --version 2>/dev/null || true)"
    client="${client#Docker version }"; client="${client%%,*}"
    if preflight_version_ge "$client" "$PREFLIGHT_MIN_DOCKER"; then
      ready+=("Docker CLI $client")
    else
      needs+=("Docker CLI '${client:-unknown}': install stable version $PREFLIGHT_MIN_DOCKER or newer")
      need_count=$((need_count + 1))
    fi
    if ! compose="$(docker compose version --short 2>/dev/null)" || [ -z "$compose" ]; then
      needs+=("Docker Compose plugin: install version $PREFLIGHT_MIN_COMPOSE or newer (docker compose)")
      need_count=$((need_count + 1))
    elif preflight_version_ge "$compose" "$PREFLIGHT_MIN_COMPOSE"; then
      ready+=("Docker Compose plugin $compose")
    else
      needs+=("Docker Compose plugin '$compose': install stable version $PREFLIGHT_MIN_COMPOSE or newer")
      need_count=$((need_count + 1))
    fi

    # DOCKER_CONTEXT takes precedence over DOCKER_HOST, as in Docker itself.
    if [ -n "${DOCKER_CONTEXT:-}" ]; then
      endpoint="$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    elif [ -n "${DOCKER_HOST:-}" ]; then
      endpoint="$DOCKER_HOST"
    else
      endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    fi
    case "$endpoint" in
      unix:///*) context_ok=true; ready+=("local Docker context") ;;
      '') needs+=("Docker context: select a local Docker Unix socket"); need_count=$((need_count + 1)) ;;
      *) needs+=("Docker context '$endpoint': use a local Docker Unix socket, not a remote Docker host"); need_count=$((need_count + 1)) ;;
    esac
    if [ "$context_ok" = true ]; then
      info="$(docker info --format '{{.OSType}}|{{.Architecture}}|{{.NCPU}}|{{.MemTotal}}|{{.DockerRootDir}}|{{.OperatingSystem}}' 2>/dev/null || true)"
      if [ -n "$info" ]; then
        daemon_ok=true
        ready+=("Docker Engine is reachable")
      else
        needs+=("Docker is not reachable: start Docker and check access to its socket")
        need_count=$((need_count + 1))
      fi
    fi
  else
    needs+=("Docker Engine and CLI: install Docker $PREFLIGHT_MIN_DOCKER or newer")
    needs+=("Docker Compose plugin: install version $PREFLIGHT_MIN_COMPOSE or newer (docker compose)")
    need_count=$((need_count + 2))
    later+=("Docker Engine version, context, CPU/RAM and data storage: check after Docker is installed")
  fi

  if [ "$daemon_ok" = true ]; then
    versions="$(docker version --format '{{.Server.Version}}|{{.Server.APIVersion}}|{{.Client.Version}}' 2>/dev/null || true)"
    IFS='|' read -r engine api client <<< "$versions"
    if preflight_version_ge "$engine" "$PREFLIGHT_MIN_DOCKER"; then ready+=("Docker Engine $engine")
    else needs+=("Docker Engine '${engine:-unknown}': install stable version $PREFLIGHT_MIN_DOCKER or newer"); need_count=$((need_count + 1)); fi
    if preflight_version_ge "$api" "$PREFLIGHT_MIN_API"; then ready+=("Docker server API $api")
    else needs+=("Docker server API '${api:-unknown}': version $PREFLIGHT_MIN_API or newer required"); need_count=$((need_count + 1)); fi
    IFS='|' read -r os arch cpus memory data_root operating_system <<< "$info"
    if [ "$os" = linux ]; then ready+=("Docker runs Linux containers")
    else needs+=("Docker must run Linux containers"); need_count=$((need_count + 1)); fi
    case "$arch" in
      x86_64|amd64) ready+=("Docker architecture $arch") ;;
      aarch64|arm64) ready+=("Docker architecture $arch (AMD64 emulation checked at startup)") ;;
      *) needs+=("Docker architecture '${arch:-unknown}': use AMD64 or ARM64 with AMD64 emulation"); need_count=$((need_count + 1)) ;;
    esac
    case "$cpus" in
      ''|*[!0-9]*) needs+=("Docker CPU capacity: cannot determine; allocate at least 2 CPUs"); need_count=$((need_count + 1)) ;;
      *) if [ "$cpus" -ge 2 ]; then ready+=("Docker CPUs: $cpus (2+ required)")
         else needs+=("Docker has $cpus CPU(s); allocate at least 2"); need_count=$((need_count + 1)); fi ;;
    esac
    case "$memory" in
      ''|*[!0-9]*) needs+=("Docker RAM capacity: cannot determine; allocate at least 4 GiB"); need_count=$((need_count + 1)) ;;
      *) if [ "$memory" -ge 3758096384 ]; then ready+=("Docker RAM: at least 4 GiB allocated")
         else needs+=("Docker needs at least 4 GiB of allocated RAM (3.5 GiB reported after system reservations)"); need_count=$((need_count + 1)); fi ;;
    esac
    if [ "$os_name" = Linux ] && [ "$operating_system" != 'Docker Desktop' ] && [ -d "$data_root" ]; then
      available="$(LC_ALL=C df -Pk "$data_root" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
      case "$available" in
        ''|*[!0-9]*) needs+=("Docker data storage: cannot determine free space"); need_count=$((need_count + 1)) ;;
        *) if [ "$available" -ge "$PREFLIGHT_MIN_DISK_KIB" ]; then ready+=("Docker data storage: 20 GiB free")
           else needs+=("Docker data storage needs at least 20 GiB free"); need_count=$((need_count + 1)); fi ;;
      esac
    fi
  elif command -v docker >/dev/null 2>&1; then
    later+=("Docker Engine version, CPU/RAM and data storage: check when Docker is reachable")
  fi

  if [ -n "${DOCKER_API_VERSION:-}" ]; then
    if preflight_version_ge "$DOCKER_API_VERSION" "$PREFLIGHT_MIN_API"; then ready+=("DOCKER_API_VERSION $DOCKER_API_VERSION")
    else needs+=("DOCKER_API_VERSION '$DOCKER_API_VERSION': unset it or use $PREFLIGHT_MIN_API or newer"); need_count=$((need_count + 1)); fi
  fi
  while [ ! -d "$target" ] && [ "$target" != / ]; do target="$(dirname "$target")"; done
  if [ -w "$target" ]; then ready+=("installation directory is writable")
  else needs+=("installation directory is not writable: $target"); need_count=$((need_count + 1)); fi
  if command -v df >/dev/null 2>&1 && command -v awk >/dev/null 2>&1; then
    available="$(LC_ALL=C df -Pk "$target" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
    case "$available" in
      ''|*[!0-9]*) needs+=("installation storage: cannot determine free space at $target"); need_count=$((need_count + 1)) ;;
      *) if [ "$available" -ge 102400 ]; then ready+=("installation storage: 100 MiB free")
         else needs+=("at least 100 MiB of free space is required for installation files"); need_count=$((need_count + 1)); fi ;;
    esac
  else
    later+=("installation storage: check when df and awk are available")
  fi

  if [ "$quiet" != quiet ] || [ "$need_count" -gt 0 ]; then
    [ "$need_count" -eq 0 ] || output_fd=2
    {
      printf '\nBasicrum host requirements\n'
      printf 'Ready:\n'
      for item in ${ready[@]+"${ready[@]}"}; do printf '  ✓ %s\n' "$item"; done
      if [ "$need_count" -gt 0 ]; then
        printf 'Needs action:\n'
        for item in ${needs[@]+"${needs[@]}"}; do printf '  ✗ %s\n' "$item"; done
      fi
      if [ "${#later[@]}" -gt 0 ]; then
        printf 'Check after the actions above:\n'
        for item in ${later[@]+"${later[@]}"}; do printf '  ? %s\n' "$item"; done
      fi
    } >&"$output_fd"
  fi
  if [ "$need_count" -gt 0 ]; then
    printf 'Preflight failed: fix the items under Needs action, then run the same installer command again.\n' >&2
    return 1
  fi
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
