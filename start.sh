#!/usr/bin/env bash
#
# start.sh: installer and converger for the Basicrum single-server community
# distribution.
#
# The first run creates .env with generated secrets and writes the Traefik
# configuration for the TLS mode you choose, then pulls the images and starts
# the stack. Every later run retains .env settings and secrets, re-derives the
# Traefik files, and converges the containers. The downloadable installer
# passes its bundled application version as a flag, which updates only that
# version; other flags override stored values. Prompts appear only for values
# that are still missing, and only when running in a terminal.
#
#   ./start.sh                                   interactive first run
#   ./start.sh --domain rum.example.com --tls letsencrypt --email you@example.com
#   ./start.sh --domain rum.example.com --tls cloudflare --cert origin.pem --key origin.key
#   ./start.sh --domain rum.example.com --tls custom --cert fullchain.pem --key privkey.pem
#   ./start.sh --domain rum.example.com --tls none --public-url https://rum.example.com
#   ./start.sh --version <tag>               internal image-tag override
#   ./start.sh --help
#
# Requirements are enforced by lib/preflight.sh before configuration changes.

set -euo pipefail

CALLER_DIR="$PWD"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=".env"
TRAEFIK_STATIC="traefik/traefik.yml"
TRAEFIK_TLS_DYNAMIC="traefik/dynamic/tls.yml"
SSL_DIR="traefik/ssl"

DEFAULT_BASICRUM_VERSION="0.0.1"
DEFAULT_TRAEFIK_VERSION="v3.7.16"
DEFAULT_POSTGRES_VERSION="17.5"
DEFAULT_CLICKHOUSE_VERSION="26.8.34.13-alpine"
ACME_STAGING_CA="https://acme-staging-v02.api.letsencrypt.org/directory"
WAIT_TIMEOUT_SECONDS=600

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
else
  BOLD=""; RED=""; YELLOW=""; GREEN=""; RESET=""
fi
info() { printf '%s\n' "$*"; }
step() { printf '\n%s%s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'USAGE'
Usage: ./start.sh [options]

Site
  --domain NAME          public hostname, e.g. rum.example.com
  --tls MODE             cloudflare   Cloudflare Origin CA certificate, Full (strict)
                         letsencrypt  Traefik obtains and renews a Let's Encrypt
                                      certificate (DNS must point here; 80 and 443 open)
                         custom       another certificate and key (see --cert/--key)
                         none         plain HTTP; your own reverse proxy terminates TLS
  --email ADDRESS        contact address for Let's Encrypt (letsencrypt mode)
  --acme-staging         use Let's Encrypt's staging CA: test certificates, no rate limits
  --cert FILE            certificate (PEM, with its chain) to install, custom mode
  --key FILE             its private key (PEM), custom mode
  --public-url URL       what browsers use to reach the site; derived from the domain,
                         mode and ports when not given (set it when a proxy in front
                         changes scheme or port)
  --http-port N          host port for HTTP (default 80)
  --https-port N         host port for HTTPS (default 443; letsencrypt and custom modes)

Images and settings
  --version TAG          shared tag for the three Basicrum images (installer supplies it)
  --set KEY=VALUE        set any other .env key, repeatable
                         (e.g. --set TELEMETRY_EXPOSE=true)

Run control
  --no-start             write .env and the Traefik files and validate; do not pull or start
  --no-pull              skip "docker compose pull"
  -y, --yes              never prompt; fail when a required value is missing
  -h, --help             this text

Existing .env values are kept unless a flag changes them. Secrets are generated
once and never rewritten. See README.md for every variable.
USAGE
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
ARG_DOMAIN=""; ARG_TLS=""; ARG_EMAIL=""; ARG_ACME_STAGING=""; ARG_CERT=""; ARG_KEY=""
ARG_PUBLIC_URL=""; ARG_HTTP_PORT=""; ARG_HTTPS_PORT=""; ARG_VERSION=""
ARG_SETS=""
NO_START=false; NO_PULL=false; ASSUME_YES=false

need_value() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain)       need_value "$@"; ARG_DOMAIN="$2"; shift 2 ;;
    --domain=*)     ARG_DOMAIN="${1#*=}"; shift ;;
    --tls)          need_value "$@"; ARG_TLS="$2"; shift 2 ;;
    --tls=*)        ARG_TLS="${1#*=}"; shift ;;
    --email)        need_value "$@"; ARG_EMAIL="$2"; shift 2 ;;
    --email=*)      ARG_EMAIL="${1#*=}"; shift ;;
    --acme-staging) ARG_ACME_STAGING=true; shift ;;
    --cert)         need_value "$@"; ARG_CERT="$2"; shift 2 ;;
    --cert=*)       ARG_CERT="${1#*=}"; shift ;;
    --key)          need_value "$@"; ARG_KEY="$2"; shift 2 ;;
    --key=*)        ARG_KEY="${1#*=}"; shift ;;
    --public-url)   need_value "$@"; ARG_PUBLIC_URL="$2"; shift 2 ;;
    --public-url=*) ARG_PUBLIC_URL="${1#*=}"; shift ;;
    --http-port)    need_value "$@"; ARG_HTTP_PORT="$2"; shift 2 ;;
    --http-port=*)  ARG_HTTP_PORT="${1#*=}"; shift ;;
    --https-port)   need_value "$@"; ARG_HTTPS_PORT="$2"; shift 2 ;;
    --https-port=*) ARG_HTTPS_PORT="${1#*=}"; shift ;;
    --version)      need_value "$@"; ARG_VERSION="$2"; shift 2 ;;
    --version=*)    ARG_VERSION="${1#*=}"; shift ;;
    --set)          need_value "$@"; ARG_SETS="${ARG_SETS}${2}"$'\n'; shift 2 ;;
    --set=*)        ARG_SETS="${ARG_SETS}${1#*=}"$'\n'; shift ;;
    --no-start)     NO_START=true; shift ;;
    --no-pull)      NO_PULL=true; shift ;;
    -y|--yes)       ASSUME_YES=true; shift ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage >&2; die "unknown option: $1" ;;
  esac
done

INTERACTIVE=false
if [ -t 0 ] && [ -t 1 ] && [ "$ASSUME_YES" = false ]; then INTERACTIVE=true; fi

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

gen_hex() { openssl rand -hex 32; }
gen_base64() { openssl rand -base64 32; }
digest() { # digest FILE -> a checksum, or empty when the file is missing
  [ -f "$1" ] || { printf ''; return 0; }
  if have openssl; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else cksum "$1" | awk '{print $1}'; fi
}

# ask VAR "prompt" "default": interactive prompt into VAR
ask() {
  local var="$1" prompt="$2" default="${3:-}" answer=""
  if [ -n "$default" ]; then printf '%s [%s]: ' "$prompt" "$default"
  else printf '%s: ' "$prompt"; fi
  read -r answer
  [ -n "$answer" ] || answer="$default"
  printf -v "$var" '%s' "$answer"
}

# .env access. Values are read and written as plain KEY=VALUE lines; one layer
# of matching quotes is stripped when reading.
env_get() {
  [ -f "$ENV_FILE" ] || return 0
  local line
  line="$(grep -E "^$1=" "$ENV_FILE" | tail -n 1 || true)"
  [ -n "$line" ] || return 0
  line="${line#*=}"
  case "$line" in
    \"*\") line="${line#\"}"; line="${line%\"}" ;;
    \'*\') line="${line#\'}"; line="${line%\'}" ;;
  esac
  printf '%s' "$line"
}
env_has() { [ -f "$ENV_FILE" ] && grep -qE "^$1=" "$ENV_FILE"; }
env_set() { # env_set KEY VALUE: replace the key's line, or append it
  local key="$1" tmp
  tmp="$(mktemp "${ENV_FILE}.XXXXXX")"
  if env_has "$key"; then
    NEWVAL="$2" awk -v key="$key" '
      BEGIN { val = ENVIRON["NEWVAL"] }
      index($0, key "=") == 1 { print key "=" val; next }
      { print }' "$ENV_FILE" > "$tmp"
  else
    { [ -f "$ENV_FILE" ] && cat "$ENV_FILE"; printf '%s=%s\n' "$key" "$2"; } > "$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}
env_default() { # env_default KEY VALUE: set only when the key is missing or empty
  if [ -z "$(env_get "$1")" ]; then env_set "$1" "$2"; fi
}

normalize_domain() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's#^[a-z]*://##' -e 's#/.*$##' -e 's#:[0-9]*$##'
}
valid_domain() {
  printf '%s' "$1" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$'
}
valid_port() { printf '%s' "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
normalize_tls() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    1|3|cloudflare|cf|custom|cert|certificate) printf 'custom' ;;
    2|letsencrypt|le|acme) printf 'letsencrypt' ;;
    4|none|http|plain) printf 'none' ;;
    *) printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
step "Basicrum single-server install"

. "$SCRIPT_DIR/lib/preflight.sh"
preflight_check "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# .env: create the template on the first run
# ---------------------------------------------------------------------------
FIRST_RUN=false
if [ ! -f "$ENV_FILE" ]; then
  FIRST_RUN=true
  umask 077
  cat > "$ENV_FILE" <<ENVTEMPLATE
# Basicrum community install. Created by ./start.sh on $(date -u +%Y-%m-%dT%H:%MZ).
# Keep this file private: it holds every secret of the installation.
# Re-running the installer keeps settings and secrets, except that its bundled
# application image version updates BASICRUM_VERSION. It re-derives PUBLIC_URL,
# TRAEFIK_ENTRYPOINT and COMPOSE_FILE from the mode.
# Values must stay on one line, without inline comments.

# ---- Site ------------------------------------------------------------------
# Public hostname Traefik routes for.
DOMAIN=
# What browsers use to reach the dashboard; also the base of the beacon endpoint.
PUBLIC_URL=
# letsencrypt | custom | none
TLS_MODE=
# Let's Encrypt contact address (letsencrypt mode). ACME_STAGING=true gets test certificates.
ACME_EMAIL=
ACME_STAGING=false
# Host ports Traefik publishes. HTTP_BIND limits HTTP to one address; empty = every address.
HTTP_PORT=80
HTTPS_PORT=443
HTTP_BIND=
# Proxies whose X-Forwarded-* headers Traefik trusts: comma-separated IPs or CIDRs (optional).
TRAEFIK_TRUSTED_PROXY_IPS=
# Derived by start.sh from TLS_MODE; do not edit.
TRAEFIK_ENTRYPOINT=
COMPOSE_FILE=

# ---- Versions --------------------------------------------------------------
# Shared tag for the three Basicrum community application images.
BASICRUM_VERSION=
TRAEFIK_VERSION=
POSTGRES_VERSION=
CLICKHOUSE_VERSION=

# ---- Databases -------------------------------------------------------------
POSTGRES_USER=basicrum
POSTGRES_DB=basicrum
# URL-safe characters only: it is embedded in the backend's connection URL.
POSTGRES_PASSWORD=
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=

# ---- Application secrets (generated once) ----------------------------------
NEXTAUTH_SECRET=
JWT_SECRET=
COOKIE_SECRET=
REFRESH_TOKEN_SECRET=
# AES-256 key (base64, 32 bytes) protecting AI provider keys that organisations store.
ORG_TOKEN_ENC_KEY_V1=

# ---- Options ---------------------------------------------------------------
# true exposes Prometheus metrics at /telemetry on each service's internal port.
TELEMETRY_EXPOSE=false
# yes lets a beacon carry its own timestamp or client IP (only for the beacon simulator).
ALLOW_BEACON_TIMESTAMP_OVERRIDE=no
ALLOW_BEACON_IP_OVERRIDE=no
BEACON_MAX_CONCURRENCY=100
BEACON_LOG_LEVEL=info
# true shows the AI features (chat, insights, AI keys settings).
NEXT_PUBLIC_ENABLE_CHATBOT=
# Public demo mode: the login page signs in with the account below.
NEXT_PUBLIC_IS_DEMO=false
NEXT_PUBLIC_DEMO_EMAIL=
NEXT_PUBLIC_DEMO_PASSWORD=
# Account allowed to use the cross-organisation admin endpoints (optional).
SUPER_ADMIN_EMAIL=
ENVTEMPLATE
  ok "created $ENV_FILE"
else
  chmod 600 "$ENV_FILE"
  ok "keeping the existing $ENV_FILE"
fi

# ---------------------------------------------------------------------------
# Site settings: flag > stored value > prompt (interactive) or default
# ---------------------------------------------------------------------------
PREV_TLS_MODE="$(env_get TLS_MODE)"

DOMAIN="${ARG_DOMAIN:-$(env_get DOMAIN)}"
if [ -z "$DOMAIN" ] && [ "$INTERACTIVE" = true ]; then
  ask DOMAIN "Public hostname of this Basicrum install (e.g. rum.example.com)"
fi
[ -n "$DOMAIN" ] || die "no domain: pass --domain NAME (or run interactively)"
DOMAIN="$(normalize_domain "$DOMAIN")"
valid_domain "$DOMAIN" || die "'$DOMAIN' is not a hostname"

TLS_MODE="$(env_get TLS_MODE)"
if [ -n "$ARG_TLS" ]; then
  TLS_MODE="$(normalize_tls "$ARG_TLS")"
  [ -n "$TLS_MODE" ] || die "--tls must be cloudflare, letsencrypt, custom or none"
fi
if [ -z "$TLS_MODE" ] && [ "$INTERACTIVE" = true ]; then
  info ""
  info "How should HTTPS work?"
  info "  1) Cloudflare: use an Origin CA certificate with Full (strict) encryption."
  info "  2) Let's Encrypt: Traefik obtains and renews the certificate."
  info "     DNS for $DOMAIN must point at this server and ports 80 and 443 must be reachable."
  info "  3) Your own certificate and private key."
  info "  4) None: plain HTTP, your own reverse proxy in front terminates TLS."
  while [ -z "$TLS_MODE" ]; do
    ask choice "Choice" "1"
    TLS_MODE="$(normalize_tls "$choice")"
    [ -n "$TLS_MODE" ] || info "Please answer 1, 2, 3 or 4."
  done
fi
[ -n "$TLS_MODE" ] || die "no TLS mode: pass --tls cloudflare|letsencrypt|custom|none (or run interactively)"

ACME_EMAIL="${ARG_EMAIL:-$(env_get ACME_EMAIL)}"
if [ "$TLS_MODE" = letsencrypt ]; then
  if [ -z "$ACME_EMAIL" ] && [ "$INTERACTIVE" = true ]; then
    ask ACME_EMAIL "Contact e-mail for Let's Encrypt (expiry notices)"
  fi
  [ -n "$ACME_EMAIL" ] || die "Let's Encrypt needs a contact address: pass --email ADDRESS"
  printf '%s' "$ACME_EMAIL" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' || die "'$ACME_EMAIL' is not an e-mail address"
fi

HTTP_PORT="${ARG_HTTP_PORT:-$(env_get HTTP_PORT)}"; HTTP_PORT="${HTTP_PORT:-80}"
HTTPS_PORT="${ARG_HTTPS_PORT:-$(env_get HTTPS_PORT)}"; HTTPS_PORT="${HTTPS_PORT:-443}"
valid_port "$HTTP_PORT" || die "--http-port: '$HTTP_PORT' is not a port"
valid_port "$HTTPS_PORT" || die "--https-port: '$HTTPS_PORT' is not a port"

# ---------------------------------------------------------------------------
# Custom certificate pair
# ---------------------------------------------------------------------------
mkdir -p "$SSL_DIR" traefik/dynamic clickhouse-config
if [ "$TLS_MODE" = custom ]; then
  if [ -n "$ARG_CERT" ] || [ -n "$ARG_KEY" ]; then
    [ -n "$ARG_CERT" ] && [ -n "$ARG_KEY" ] || die "--cert and --key go together"
  elif [ "$INTERACTIVE" = true ] && { [ ! -f "$SSL_DIR/cert.pem" ] || [ ! -f "$SSL_DIR/key.pem" ]; }; then
    ask ARG_CERT "Path to the certificate (PEM, with its chain)"
    ask ARG_KEY "Path to its private key (PEM)"
  fi
  check_pair() { # check_pair CERT KEY: die unless they are a matching PEM pair
    have openssl || return 0
    local cert_pub key_pub
    openssl x509 -noout -in "$1" >/dev/null 2>&1 || die "$1 is not a PEM certificate"
    openssl pkey -noout -in "$2" >/dev/null 2>&1 || die "$2 is not a PEM private key"
    cert_pub="$(openssl x509 -noout -pubkey -in "$1" | openssl pkey -pubin -outform DER | openssl dgst -sha256 | awk '{print $NF}')"
    key_pub="$(openssl pkey -in "$2" -pubout -outform DER | openssl dgst -sha256 | awk '{print $NF}')"
    [ "$cert_pub" = "$key_pub" ] || die "the certificate and the private key do not belong together ($1, $2)"
    openssl x509 -noout -checkhost "$DOMAIN" -in "$1" >/dev/null 2>&1 \
      || die "the certificate does not cover $DOMAIN; Cloudflare Full (strict) and browsers require a matching hostname"
    openssl x509 -noout -checkend 0 -in "$1" >/dev/null 2>&1 \
      || die "the certificate has expired; Cloudflare Full (strict) and browsers require a valid certificate"
    ok "certificate pair checked: $(openssl x509 -noout -enddate -in "$1" | sed 's/notAfter=/valid until /')"
  }
  if [ -n "$ARG_CERT" ]; then
    # Resolve both flags and prompted paths relative to where setup was invoked.
    case "$ARG_CERT" in /*) ;; *) ARG_CERT="$CALLER_DIR/$ARG_CERT" ;; esac
    case "$ARG_KEY" in /*) ;; *) ARG_KEY="$CALLER_DIR/$ARG_KEY" ;; esac
    [ -f "$ARG_CERT" ] || die "certificate not found: $ARG_CERT"
    [ -f "$ARG_KEY" ] || die "private key not found: $ARG_KEY"
    check_pair "$ARG_CERT" "$ARG_KEY"
    install -m 644 "$ARG_CERT" "$SSL_DIR/cert.pem"
    install -m 600 "$ARG_KEY" "$SSL_DIR/key.pem"
    ok "installed the certificate pair into $SSL_DIR/"
  else
    [ -f "$SSL_DIR/cert.pem" ] && [ -f "$SSL_DIR/key.pem" ] \
      || die "custom TLS needs $SSL_DIR/cert.pem and $SSL_DIR/key.pem: pass --cert and --key, or copy them there"
    check_pair "$SSL_DIR/cert.pem" "$SSL_DIR/key.pem"
  fi
  chmod 600 "$SSL_DIR/key.pem"
fi

# ---------------------------------------------------------------------------
# Write .env
# ---------------------------------------------------------------------------
step "Writing $ENV_FILE"

env_set DOMAIN "$DOMAIN"
env_set TLS_MODE "$TLS_MODE"
[ -n "$ACME_EMAIL" ] && env_set ACME_EMAIL "$ACME_EMAIL"
[ -n "$ARG_ACME_STAGING" ] && env_set ACME_STAGING true
env_default ACME_STAGING false
env_set HTTP_PORT "$HTTP_PORT"
env_set HTTPS_PORT "$HTTPS_PORT"

# Plain HTTP behind your own proxy listens on loopback unless told otherwise;
# when Traefik is the edge it listens on every address. Applied when the mode
# changes, so a hand-set HTTP_BIND survives ordinary re-runs.
if [ "$TLS_MODE" != "$PREV_TLS_MODE" ]; then
  if [ "$TLS_MODE" = none ]; then env_set HTTP_BIND "127.0.0.1"; else env_set HTTP_BIND ""; fi
fi
env_has HTTP_BIND || env_set HTTP_BIND ""
env_has TRAEFIK_TRUSTED_PROXY_IPS || env_set TRAEFIK_TRUSTED_PROXY_IPS ""

[ -n "$ARG_VERSION" ] && env_set BASICRUM_VERSION "$ARG_VERSION"
env_default BASICRUM_VERSION "$DEFAULT_BASICRUM_VERSION"
env_default TRAEFIK_VERSION "$DEFAULT_TRAEFIK_VERSION"
env_default POSTGRES_VERSION "$DEFAULT_POSTGRES_VERSION"
env_default CLICKHOUSE_VERSION "$DEFAULT_CLICKHOUSE_VERSION"

env_default POSTGRES_USER basicrum
env_default POSTGRES_DB basicrum
env_default CLICKHOUSE_USER default

# Secrets: generated on the first run that finds them missing, never rewritten.
generated=""
for key in POSTGRES_PASSWORD CLICKHOUSE_PASSWORD NEXTAUTH_SECRET JWT_SECRET COOKIE_SECRET REFRESH_TOKEN_SECRET; do
  if [ -z "$(env_get "$key")" ]; then env_set "$key" "$(gen_hex)"; generated="$generated $key"; fi
done
if [ -z "$(env_get ORG_TOKEN_ENC_KEY_V1)" ]; then
  env_set ORG_TOKEN_ENC_KEY_V1 "$(gen_base64)"; generated="$generated ORG_TOKEN_ENC_KEY_V1"
fi
[ -z "$generated" ] || ok "generated:$generated"

env_default TELEMETRY_EXPOSE false
env_default ALLOW_BEACON_TIMESTAMP_OVERRIDE no
env_default ALLOW_BEACON_IP_OVERRIDE no
env_default BEACON_MAX_CONCURRENCY 100
env_default BEACON_LOG_LEVEL info
for key in NEXT_PUBLIC_ENABLE_CHATBOT NEXT_PUBLIC_DEMO_EMAIL NEXT_PUBLIC_DEMO_PASSWORD SUPER_ADMIN_EMAIL; do
  env_has "$key" || env_set "$key" ""
done
env_default NEXT_PUBLIC_IS_DEMO false

# Explicit --set pairs win over everything above.
if [ -n "$ARG_SETS" ]; then
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    key="${pair%%=*}"; value="${pair#*=}"
    [ "$key" != "$pair" ] || die "--set needs KEY=VALUE, got '$pair'"
    printf '%s' "$key" | grep -Eq '^[A-Z_][A-Z0-9_]*$' || die "--set: '$key' is not a variable name"
    env_set "$key" "$value"
  done <<< "$ARG_SETS"
fi
# Derived values.
PUBLIC_URL="$(env_get PUBLIC_URL)"
if [ -n "$ARG_PUBLIC_URL" ]; then
  PUBLIC_URL="${ARG_PUBLIC_URL%/}"
elif [ -z "$PUBLIC_URL" ] || [ -n "$ARG_DOMAIN" ] || [ -n "$ARG_TLS" ] || [ -n "$ARG_HTTP_PORT" ] || [ -n "$ARG_HTTPS_PORT" ]; then
  if [ "$TLS_MODE" = none ]; then
    PUBLIC_URL="http://$DOMAIN"; [ "$HTTP_PORT" = 80 ] || PUBLIC_URL="$PUBLIC_URL:$HTTP_PORT"
  else
    PUBLIC_URL="https://$DOMAIN"; [ "$HTTPS_PORT" = 443 ] || PUBLIC_URL="$PUBLIC_URL:$HTTPS_PORT"
  fi
fi
printf '%s' "$PUBLIC_URL" | grep -Eq '^https?://[^/[:space:]]+$' || die "PUBLIC_URL must look like https://host[:port], got '$PUBLIC_URL'"
env_set PUBLIC_URL "$PUBLIC_URL"
if [ "$TLS_MODE" = none ]; then
  env_set TRAEFIK_ENTRYPOINT web
  env_set COMPOSE_FILE docker-compose.yml
else
  env_set TRAEFIK_ENTRYPOINT websecure
  env_set COMPOSE_FILE docker-compose.yml:compose.https.yml
fi
ok "domain $DOMAIN, TLS $TLS_MODE, public URL $PUBLIC_URL"

# ---------------------------------------------------------------------------
# Traefik configuration, derived from .env on every run
# ---------------------------------------------------------------------------
step "Writing the Traefik configuration"
TRAEFIK_BEFORE="$(digest "$TRAEFIK_STATIC")$(digest "$TRAEFIK_TLS_DYNAMIC")"

trusted_ips="$(env_get TRAEFIK_TRUSTED_PROXY_IPS)"
forwarded_block=""
if [ -n "$trusted_ips" ]; then
  forwarded_block=$'    forwardedHeaders:\n      trustedIPs:\n'
  for ip in $(printf '%s' "$trusted_ips" | tr ',' ' '); do
    forwarded_block="${forwarded_block}        - ${ip}"$'\n'
  done
elif [ "$TLS_MODE" = none ]; then
  # Behind your own proxy the real client address arrives in X-Forwarded-For;
  # the beacon service needs it for GeoIP. Only that proxy should reach this port.
  forwarded_block=$'    forwardedHeaders:\n      insecure: true\n'
fi

{
  cat <<TRAEFIK_HEAD
# Traefik static configuration, written by ./start.sh for TLS mode "$TLS_MODE".
# Change .env and re-run ./start.sh instead of editing this file.
global:
  checkNewVersion: false
  sendAnonymousUsage: false
log:
  level: INFO
ping:
  entryPoint: traefik
providers:
  docker:
    exposedByDefault: false
  file:
    directory: /etc/traefik/dynamic
    watch: true
entryPoints:
  traefik:
    address: "127.0.0.1:8080"
  web:
    address: ":80"
TRAEFIK_HEAD
  printf '%s' "$forwarded_block"
  case "$TLS_MODE" in
    none) ;;
    *)
      # The redirect names the entry point when HTTPS sits on 443; on any other
      # published port browsers must be sent to that port explicitly.
      redirect_to="websecure"
      [ "$HTTPS_PORT" = 443 ] || redirect_to="\":$HTTPS_PORT\""
      cat <<TRAEFIK_TLS
    http:
      redirections:
        entryPoint:
          to: $redirect_to
          scheme: https
  websecure:
    address: ":443"
TRAEFIK_TLS
      printf '%s' "$forwarded_block"
      ;;
  esac
  if [ "$TLS_MODE" = letsencrypt ]; then
    ca_line=""
    [ "$(env_get ACME_STAGING)" = true ] && ca_line="      caServer: $ACME_STAGING_CA"$'\n'
    cat <<TRAEFIK_ACME
    http:
      tls:
        certResolver: letsencrypt
certificatesResolvers:
  letsencrypt:
    acme:
      email: $(env_get ACME_EMAIL)
      storage: /letsencrypt/acme.json
${ca_line}      httpChallenge:
        entryPoint: web
TRAEFIK_ACME
  elif [ "$TLS_MODE" = custom ]; then
    cat <<'TRAEFIK_CUSTOM'
    http:
      tls: {}
TRAEFIK_CUSTOM
  fi
} > "$TRAEFIK_STATIC"

if [ "$TLS_MODE" = custom ]; then
  cat > "$TRAEFIK_TLS_DYNAMIC" <<'TLS_DYNAMIC'
# Written by ./start.sh: the certificate pair in traefik/ssl/, served for every
# hostname. Replace the two files to rotate; Traefik picks the change up when
# this file is written again (re-run ./start.sh, or touch it).
tls:
  certificates:
    - certFile: /etc/certs/cert.pem
      keyFile: /etc/certs/key.pem
  stores:
    default:
      defaultCertificate:
        certFile: /etc/certs/cert.pem
        keyFile: /etc/certs/key.pem
TLS_DYNAMIC
else
  rm -f "$TRAEFIK_TLS_DYNAMIC"
fi
TRAEFIK_AFTER="$(digest "$TRAEFIK_STATIC")$(digest "$TRAEFIK_TLS_DYNAMIC")"
TRAEFIK_CHANGED=false; [ "$TRAEFIK_BEFORE" = "$TRAEFIK_AFTER" ] || TRAEFIK_CHANGED=true
ok "$TRAEFIK_STATIC written"

# ---------------------------------------------------------------------------
# Validate, pull, start
# ---------------------------------------------------------------------------
step "Validating the compose bundle"
docker compose config --quiet || die "the compose bundle does not validate; see the messages above"
ok "docker compose config is valid"

if [ "$NO_START" = true ]; then
  info ""
  info "Configuration written, nothing started (--no-start). Rerun the installer"
  info "without --no-start (and with the same --install-dir, if used) to start services."
  info "Image execution, Docker data disk, port/DNS and endpoint checks run then."
  exit 0
fi

step "Checking network prerequisites"
published_ports=("${HTTP_BIND:-$(env_get HTTP_BIND)}:$(env_get HTTP_PORT)")
# An empty HTTP_BIND means every address.
[ "${published_ports[0]#:}" = "${published_ports[0]}" ] || published_ports[0]="0.0.0.0${published_ports[0]}"
if [ "$TLS_MODE" != none ]; then published_ports+=("0.0.0.0:$(env_get HTTPS_PORT)"); fi
project_name="${COMPOSE_PROJECT_NAME:-$(env_get COMPOSE_PROJECT_NAME)}"
preflight_network "$DOMAIN" "$TLS_MODE" "${project_name:-basicrum}" "$SCRIPT_DIR" "${published_ports[@]}"

if [ "$NO_PULL" = false ]; then
  step "Pulling images"
  docker compose pull || die "pull failed; is this host allowed to reach Docker Hub?"
fi

step "Checking image execution and Docker storage"
preflight_images "basicrum/backend_community:$(env_get BASICRUM_VERSION)" "clickhouse/clickhouse-server:$(env_get CLICKHOUSE_VERSION)"

step "Starting the stack (waiting for health checks, up to ${WAIT_TIMEOUT_SECONDS}s)"
traefik_existed=""
traefik_existed="$(docker compose ps -q traefik 2>/dev/null || true)"
if ! docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS"; then
  info ""
  die "the stack did not come up healthy. Inspect with: docker compose ps  /  docker compose logs --tail=100"
fi
if [ "$TRAEFIK_CHANGED" = true ] && [ -n "$traefik_existed" ]; then
  # The static configuration is a bind-mounted file; a running container keeps
  # the old one until it is recreated.
  docker compose up -d --force-recreate --no-deps --wait --wait-timeout "$WAIT_TIMEOUT_SECONDS" traefik \
    || die "Traefik did not become healthy after its configuration changed; see docker compose logs traefik"
  ok "traefik recreated with the new configuration"
fi
ok "all services are up"

# Traefik builds its routers a moment after it starts; wait until the login
# page answers through it, so "running" means reachable.
wait_for_edge() {
  local addr port scheme
  local curl_options=()
  addr="$(env_get HTTP_BIND)"
  case "$addr" in
    ''|0.0.0.0) addr=127.0.0.1 ;;
    '::'|'[::]') addr='[::1]' ;;
    *:*) case "$addr" in \[*) ;; *) addr="[$addr]" ;; esac ;;
  esac
  if [ "$TLS_MODE" = none ]; then
    scheme=http; port="$HTTP_PORT"
  else
    scheme=https; port="$HTTPS_PORT"; curl_options+=(-k)
  fi
  preflight_wait_url "$scheme://$DOMAIN:$port/auth/login" 30 'Local dashboard through Traefik' \
    ${curl_options[@]+"${curl_options[@]}"} --resolve "$DOMAIN:$port:$addr"
  if [ "$TLS_MODE" = letsencrypt ]; then
    # Check real DNS and TLS trust as well as the local route. Staging CA
    # certificates are intentionally untrusted and are only used for rehearsal.
    curl_options=()
    if [ "$(env_get ACME_STAGING)" = true ]; then curl_options+=(-k); fi
    preflight_wait_url "$PUBLIC_URL/auth/login" 120 'Public HTTPS dashboard' ${curl_options[@]+"${curl_options[@]}"}
  fi
}
wait_for_edge

# ---------------------------------------------------------------------------
# What now
# ---------------------------------------------------------------------------
step "Basicrum is running"
cat <<SUMMARY

  Dashboard:        $PUBLIC_URL
  Beacon endpoint:  $PUBLIC_URL/beacon/catcher
  Images:           basicrum/{backend,frontend,beacon_service}_community:$(env_get BASICRUM_VERSION)
SUMMARY
case "$TLS_MODE" in
  letsencrypt)
    info "  Certificate:      Traefik requests it from Let's Encrypt now and renews it itself;"
    info "                    'docker compose logs traefik' shows the ACME exchange." ;;
  custom)
    info "  Certificate:      $SSL_DIR/cert.pem (rerun the installer with --cert and --key to rotate)" ;;
  none)
    info "  HTTP:             $(env_get HTTP_BIND | sed 's/^$/every address/'):$HTTP_PORT, plain. Point your reverse proxy at it,"
    info "                    forward the Host header unchanged, and make $PUBLIC_URL reach it." ;;
esac
cat <<FIRSTRUN

First run
  1. Create the first account, which becomes the organisation's admin:
       $PUBLIC_URL/auth/register?firstUser=true
     Passwords need at least 15 characters. Every later account needs an invite
     code, created under Settings > Users.
  2. Add your site under Settings > Sites, install the Boomerang snippet it
     shows (the beacon endpoint above is already filled in), then press Verify.
  3. Optional, to see the dashboards before your own site sends beacons: seed
     the verified test site the beacon simulator targets, then run the
     simulator from the Basicrum repository against the beacon endpoint:
       docker compose exec basicrum_backend node build/scripts/seedVerifiedSite.js

Day to day
  docker compose ps                         state of the six containers
  docker compose logs -f basicrum_backend   follow one service's log
  Rerun the latest installer command to apply image and configuration updates.
  docker compose down                       stop (data stays in the named volumes)

FIRSTRUN
