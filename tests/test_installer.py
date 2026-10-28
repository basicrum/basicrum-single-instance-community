"""Exercise the built installer without starting containers or reading live state."""

from functools import partial
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import subprocess
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
REAL_CURL = shutil.which("curl")
REAL_DOCKER = shutil.which("docker")


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.image_version = re.search(
            r'^DEFAULT_BASICRUM_VERSION="([^"]+)"$', (ROOT / "start.sh").read_text(), re.MULTILINE
        ).group(1)
        cls.build_dir = tempfile.TemporaryDirectory(prefix="basicrum-build-test-")
        cls.installer = Path(cls.build_dir.name) / "install.sh"
        subprocess.run(
            ["python3", str(ROOT / "scripts/build-installer.py"), "--output", str(cls.installer)],
            check=True, capture_output=True,
        )
        cls.script = cls.installer.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.build_dir.cleanup()

    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="basicrum-test-")
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.dest = self.home / "basicrum"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        docker = self.bin / "docker"
        docker.write_text("""#!/usr/bin/env bash
set -eu
printf '%s\\n' "$*" >> "$TEST_DOCKER_LOG"
case "$*" in
  'context inspect'*) echo "${TEST_DOCKER_ENDPOINT:-unix:///var/run/docker.sock}" ;;
  'info --format '*)
    [ "${TEST_DOCKER_STATUS:-0}" = 0 ] || exit "$TEST_DOCKER_STATUS"
    echo "${TEST_DOCKER_OS:-linux}|${TEST_DOCKER_ARCH:-amd64}|${TEST_DOCKER_CPUS:-4}|${TEST_DOCKER_MEMORY:-8589934592}|/docker-test-data|Docker Desktop" ;;
  'compose version --short') printf '%s\\n' "${TEST_COMPOSE_VERSION-2.24.0}"; exit "${TEST_COMPOSE_STATUS:-0}" ;;
  'version --format '*) echo "${TEST_ENGINE_VERSION-29.0.0}|${TEST_API_VERSION-1.55}|${TEST_CLIENT_VERSION-29.0.0}" ;;
  'compose config --quiet'|'compose pull') ;;
  'compose ps -q traefik') printf '%s\\n' "${TEST_TRAEFIK_ID:-}" ;;
  'compose up -d --force-recreate '*) exit "${TEST_RECREATE_STATUS:-0}" ;;
  'compose up '*) exit "${TEST_UP_STATUS:-0}" ;;
  'ps -aq') printf '%s\\n' "${TEST_RUNNING_CONTAINER:-}" ;;
  'inspect --format '*) printf '%s\\n' "${TEST_CONTAINER_RECORD:-}" ;;
  'run '*basicrum/backend_community:*) exit "${TEST_EMULATION_STATUS:-0}" ;;
  'run '*clickhouse/clickhouse-server:*) printf '%s\\n' "${TEST_DOCKER_DISK_KIB:-52428800}"; exit "${TEST_CLICKHOUSE_STATUS:-0}" ;;
  *) printf 'Unexpected Docker call: %s\\n' "$*" >&2; exit 90 ;;
esac
""")
        docker.chmod(0o755)
        curl = self.bin / "curl"
        curl.write_text("#!/usr/bin/env bash\nprintf '%s\\n' \"$*\" >> \"$TEST_CURL_LOG\"\nprintf '%s' \"${TEST_CURL_STATUS:-200}\"\n")
        curl.chmod(0o755)
        for name, contents in {
            "df": 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\\nfixture 999999999 0 %s 1%% /\\n" "${TEST_FREE_KIB:-52428800}"',
            "uname": 'printf "%s\\n" "${TEST_HOST_OS:-Linux}"',
            "ss": 'printf "%s\\n" "${TEST_SS_OUTPUT:-}"',
            "lsof": 'printf "%s\\n" "${TEST_LSOF_OUTPUT:-}"',
            "getent": '[ "${TEST_DNS_STATUS:-0}" = 0 ] && echo "127.0.0.1 STREAM localhost"',
            "dscacheutil": '[ "${TEST_DNS_STATUS:-0}" = 0 ] && echo "ip_address: 127.0.0.1"',
        }.items():
            executable = self.bin / name
            executable.write_text(f"#!/usr/bin/env bash\n{contents}\n")
            executable.chmod(0o755)
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=f"{self.bin}:{os.environ['PATH']}",
                        TEST_DOCKER_LOG=str(self.root / "docker.log"),
                        TEST_CURL_LOG=str(self.root / "curl.log"))
        # Do not let a developer's Compose overrides affect fixtures.
        for name in ("COMPOSE_FILE", "COMPOSE_PROJECT_NAME", "COMPOSE_ENV_FILES", "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_API_VERSION"):
            self.env.pop(name, None)
        self.flags = ["--domain", "localhost", "--tls", "none", "--http-port", "8080", "--no-start", "--yes"]

    def run_installer(self, flags=None, script=None):
        result = subprocess.run(
            ["bash", "-s", "--", *(self.flags if flags is None else flags)],
            input=self.script if script is None else script,
            cwd=self.root, env=self.env, capture_output=True, timeout=30,
        )
        return result

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode())

    def test_embedded_files_are_readable_and_preserved(self):
        expected = {
            "start.sh", "lib/preflight.sh", "README.md", "docker-compose.yml", "compose.https.yml",
            "clickhouse-config/system-logs.xml",
        }
        files = re.findall(rb"^  # Begin embedded file: (.+)$", self.script, re.MULTILINE)
        self.assertEqual(len(files), len(set(files)))
        self.assertEqual({name.decode() for name in files}, expected)
        self.assert_ok(self.run_installer())
        for name in expected:
            with self.subTest(name=name):
                source = (ROOT / name).read_bytes()
                self.assertIn(source, self.script)
                self.assertEqual((self.dest / name).read_bytes(), source)
        checksum = self.installer.with_name("install.sh.sha256").read_text().split()[0]
        self.assertEqual(checksum, hashlib.sha256(self.script).hexdigest())

    def test_unattended_install_and_rerun_preserve_state(self):
        first = self.run_installer()
        self.assert_ok(first)
        command = b"curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash"
        self.assertIn(command, first.stdout)
        self.assertNotIn(b"start.sh", first.stdout)
        before = (self.dest / ".env").read_bytes()
        self.assertIn(f"BASICRUM_VERSION={self.image_version}\n".encode(), before)
        self.assertEqual((self.dest / ".env").stat().st_mode & 0o777, 0o600)
        for name in ("user-data/sentinel", "traefik/ssl/cert.pem", "traefik/ssl/key.pem"):
            path = self.dest / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("keep this test data")
        rerun = self.run_installer(["--yes", "--no-start"])
        self.assert_ok(rerun)
        self.assertIn(command, rerun.stdout)
        self.assertEqual(before, (self.dest / ".env").read_bytes())
        for name in ("user-data/sentinel", "traefik/ssl/cert.pem", "traefik/ssl/key.pem"):
            self.assertEqual((self.dest / name).read_text(), "keep this test data")
        calls = (self.root / "docker.log").read_text()
        self.assertNotIn("compose pull", calls)
        self.assertNotIn("compose up", calls)

    def test_new_installer_release_advances_images_without_reentering_cloudflare_cert(self):
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(self.root / "origin.key"), "-out", str(self.root / "origin.pem"),
            "-days", "1", "-subj", "/CN=rum.example.com",
        ], check=True, capture_output=True, timeout=30)
        initial = ["--domain", "rum.example.com", "--tls", "cloudflare",
                   "--cert", "origin.pem", "--key", "origin.key", "--no-start", "--yes"]
        self.assert_ok(self.run_installer(initial))
        original_env = (self.dest / ".env").read_bytes()
        cert = (self.dest / "traefik/ssl/cert.pem").read_bytes()
        key = (self.dest / "traefik/ssl/key.pem").read_bytes()
        current = f"bundle_version='{self.image_version}'".encode()
        self.assertIn(current, self.script)
        major, minor, patch = map(int, self.image_version.split("."))
        next_version = f"{major}.{minor}.{patch + 1}"
        next_installer = self.script.replace(current, f"bundle_version='{next_version}'".encode(), 1)
        self.assert_ok(self.run_installer(["--no-start", "--yes"], script=next_installer))
        upgraded_env = (self.dest / ".env").read_bytes()
        self.assertEqual(upgraded_env, original_env.replace(
            f"BASICRUM_VERSION={self.image_version}\n".encode(),
            f"BASICRUM_VERSION={next_version}\n".encode(),
        ))
        self.assertEqual((self.dest / "traefik/ssl/cert.pem").read_bytes(), cert)
        self.assertEqual((self.dest / "traefik/ssl/key.pem").read_bytes(), key)
        self.assert_ok(self.run_installer(["--no-start", "--yes"], script=next_installer))
        self.assertEqual((self.dest / ".env").read_bytes(), upgraded_env)

    def test_install_dir_with_spaces_and_unknown_option(self):
        dest = self.root / "path with spaces"
        result = self.run_installer(["--install-dir", str(dest), *self.flags])
        self.assert_ok(result)
        self.assertIn(b" | bash -s -- --install-dir ", result.stdout)
        self.assertTrue((dest / ".env").exists())
        result = self.run_installer(["--not-an-option"])
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.dest.exists())

    def test_unrelated_directory_is_untouched(self):
        self.dest.mkdir()
        sentinel = self.dest / "README.md"
        sentinel.write_text("unrelated project")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"not an installer-managed directory", result.stderr)
        self.assertEqual(sentinel.read_text(), "unrelated project")
        self.assertEqual(len(list(self.dest.iterdir())), 1)

    def test_missing_docker_daemon_does_not_create_install(self):
        self.env["TEST_DOCKER_STATUS"] = "1"
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Docker is not reachable", result.stderr)
        self.assertFalse(self.dest.exists())

    def test_unsupported_versions_fail_before_installation(self):
        cases = [
            ("TEST_ENGINE_VERSION", "20.10.9", b"Docker Engine"),
            ("TEST_ENGINE_VERSION", "unknown", b"Docker Engine"),
            ("TEST_ENGINE_VERSION", "", b"Docker Engine"),
            ("TEST_CLIENT_VERSION", "19.03.15", b"Docker CLI"),
            ("TEST_API_VERSION", "1.39", b"Docker server API"),
            ("DOCKER_API_VERSION", "1.39", b"DOCKER_API_VERSION"),
            ("TEST_COMPOSE_VERSION", "v1.29.2", b"Docker Compose"),
            ("TEST_COMPOSE_VERSION", "2.9.0", b"Docker Compose"),
            ("TEST_COMPOSE_VERSION", "2.23.3", b"Docker Compose"),
            ("TEST_COMPOSE_VERSION", "2.24.0-rc.1", b"Docker Compose"),
            ("TEST_COMPOSE_VERSION", "not-a-version", b"Docker Compose"),
            ("TEST_COMPOSE_VERSION", "", b"Docker Compose"),
            ("TEST_COMPOSE_STATUS", "1", b"Compose plugin"),
        ]
        for name, value, message in cases:
            with self.subTest(name=name, value=value):
                self.env[name] = value
                try:
                    result = self.run_installer()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertFalse(self.dest.exists())
                finally:
                    self.env.pop(name)

    def test_minimum_versions_and_vendor_suffixes_work(self):
        for engine, api, compose in [
            ("20.10.10", "1.40", "v2.24.0"),
            ("20.10.10+dfsg1-1", "1.41", "2.24.1"),
            ("29.7.2-0ubuntu1~24.04.1", "1.55", "v5.4.0"),
        ]:
            with self.subTest(engine=engine, compose=compose):
                self.env.update(TEST_ENGINE_VERSION=engine, TEST_CLIENT_VERSION=engine,
                                TEST_API_VERSION=api, TEST_COMPOSE_VERSION=compose)
                self.assert_ok(self.run_installer())

    def test_host_requirements_fail_before_installation(self):
        cases = [
            ("TEST_DOCKER_ENDPOINT", "ssh://remote.example", b"local Docker"),
            ("TEST_DOCKER_OS", "windows", b"Linux containers"),
            ("TEST_DOCKER_ARCH", "ppc64le", b"architecture"),
            ("TEST_DOCKER_CPUS", "1", b"at least 2"),
            ("TEST_DOCKER_MEMORY", "2147483648", b"RAM"),
            ("TEST_DOCKER_MEMORY", "unknown", b"capacity"),
            ("TEST_FREE_KIB", "10", b"100 MiB"),
            ("TEST_HOST_OS", "FreeBSD", b"Linux"),
        ]
        for name, value, message in cases:
            with self.subTest(name=name, value=value):
                self.env[name] = value
                try:
                    result = self.run_installer()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertFalse(self.dest.exists())
                finally:
                    self.env.pop(name)

    def test_requirement_failure_preserves_an_existing_install(self):
        self.assert_ok(self.run_installer())
        snapshots = {name: (self.dest / name).read_bytes() for name in (".env", "start.sh", "docker-compose.yml")}
        self.env["TEST_COMPOSE_VERSION"] = "2.23.0"
        result = self.run_installer([*self.flags, "--set", "BEACON_LOG_LEVEL=debug"])
        self.assertNotEqual(result.returncode, 0)
        for name, before in snapshots.items():
            self.assertEqual((self.dest / name).read_bytes(), before)

    def test_start_script_checks_versions_before_creating_env(self):
        self.dest.mkdir()
        (self.dest / "lib").mkdir()
        for name in ("start.sh", "lib/preflight.sh"):
            shutil.copyfile(ROOT / name, self.dest / name)
        self.env["TEST_ENGINE_VERSION"] = "20.10.9"
        result = subprocess.run(["bash", str(self.dest / "start.sh"), *self.flags],
                                env=self.env, cwd=self.root, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Docker Engine", result.stderr)
        self.assertFalse((self.dest / ".env").exists())

    def test_missing_curl_or_openssl_stops_installation(self):
        required = "bash docker openssl curl awk grep sed tr sort head tail mktemp chmod cp mv rm mkdir df dirname cat uname date sleep install ss getent".split()
        for missing in ("curl", "openssl"):
            with self.subTest(missing=missing):
                for name in required:
                    path = self.bin / name
                    if name == missing:
                        path.unlink(missing_ok=True)
                    elif not path.exists():
                        executable = shutil.which(name)
                        self.assertIsNotNone(executable, name)
                        path.symlink_to(executable)
                self.env["PATH"] = str(self.bin)
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing.encode(), result.stderr)
                self.assertFalse(self.dest.exists())

    def test_busy_ports_and_unresolved_dns_stop_before_pulling(self):
        self.env["TEST_SS_OUTPUT"] = "LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*"
        result = self.run_installer([flag for flag in self.flags if flag != "--no-start"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"already listening", result.stderr)
        self.env.pop("TEST_SS_OUTPUT")
        self.env["TEST_DNS_STATUS"] = "1"
        result = self.run_installer(["--domain", "rum.example.com", "--tls", "letsencrypt", "--email", "admin@example.com", "--yes"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"does not resolve", result.stderr)
        self.assertNotIn("compose pull", (self.root / "docker.log").read_text())

    def test_conflicting_configured_ports_are_rejected(self):
        result = self.run_installer([
            "--domain", "rum.example.com", "--tls", "letsencrypt",
            "--email", "admin@example.com", "--http-port", "8080",
            "--https-port", "8080", "--yes",
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"bindings overlap", result.stderr)

    def test_foreign_container_ports_are_rejected_without_host_listener(self):
        self.env.update(TEST_RUNNING_CONTAINER="fixture-id",
                        TEST_CONTAINER_RECORD="other|/another/project|0.0.0.0:8080")
        result = self.run_installer([flag for flag in self.flags if flag != "--no-start"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"another container", result.stderr)

    def test_existing_installation_ports_are_allowed(self):
        self.env.update(TEST_RUNNING_CONTAINER="fixture-id",
                        TEST_CONTAINER_RECORD=f"basicrum|{self.dest}|127.0.0.1:8080",
                        TEST_SS_OUTPUT="LISTEN 0 128 127.0.0.1:8080 0.0.0.0:*")
        self.assert_ok(self.run_installer([flag for flag in self.flags if flag != "--no-start"]))

    def test_another_directory_cannot_reuse_the_compose_project(self):
        self.env.update(TEST_RUNNING_CONTAINER="fixture-id",
                        TEST_CONTAINER_RECORD="basicrum|/another/project|127.0.0.1:8080")
        result = self.run_installer([flag for flag in self.flags if flag != "--no-start"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"another directory", result.stderr)

    def test_runtime_image_and_disk_failures_stop_before_stack_start(self):
        for name, value, message in [
            ("TEST_EMULATION_STATUS", "1", b"AMD64 backend"),
            ("TEST_CLICKHOUSE_STATUS", "1", b"ClickHouse image"),
            ("TEST_DOCKER_DISK_KIB", "1000", b"20 GiB"),
        ]:
            with self.subTest(name=name):
                self.env[name] = value
                try:
                    result = self.run_installer([flag for flag in self.flags if flag != "--no-start"])
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)
                    self.assertNotIn("compose up", (self.root / "docker.log").read_text())
                finally:
                    self.env.pop(name)

    def test_arm64_daemon_executes_amd64_probe(self):
        self.env.update(TEST_DOCKER_ARCH="aarch64", TEST_HOST_OS="Darwin")
        self.assert_ok(self.run_installer([flag for flag in self.flags if flag != "--no-start"]))
        self.assertIn("--platform linux/amd64", (self.root / "docker.log").read_text())

    def test_unhealthy_services_fail_setup(self):
        self.env["TEST_UP_STATUS"] = "1"
        result = self.run_installer([flag for flag in self.flags if flag != "--no-start"])
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"Basicrum is ready", result.stdout)

    def test_endpoint_failure_is_fatal_and_requests_have_timeouts(self):
        self.env["TEST_CURL_STATUS"] = "503"
        result = subprocess.run([
            "bash", "-euo", "pipefail", "-c", '. "$1"; preflight_wait_url http://localhost/auth/login 1 "Test dashboard"',
            "readiness", str(ROOT / "lib/preflight.sh"),
        ], env=self.env, cwd=self.root, capture_output=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"did not become ready", result.stderr)
        self.assertIn("--connect-timeout 2 --max-time 5", (self.root / "curl.log").read_text())

    def test_public_https_checks_certificate_trust(self):
        flags = ["--domain", "rum.example.com", "--tls", "letsencrypt", "--email", "admin@example.com", "--yes"]
        self.assert_ok(self.run_installer(flags))
        calls = (self.root / "curl.log").read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertIn("--resolve", calls[0])
        self.assertIn(" -k ", calls[0])
        self.assertNotIn("--resolve", calls[1])
        self.assertNotIn(" -k ", calls[1])
        self.assertIn("https://rum.example.com/auth/login", calls[1])

    def test_traefik_recreation_waits_for_health_and_propagates_failure(self):
        self.assert_ok(self.run_installer())
        self.env.update(TEST_TRAEFIK_ID="existing-traefik", TEST_RECREATE_STATUS="1")
        flags = ["--domain", "rum.example.com", "--tls", "letsencrypt", "--email", "admin@example.com", "--yes"]
        result = self.run_installer(flags)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"Traefik did not become healthy", result.stderr)
        self.assertNotIn(b"Basicrum is ready", result.stdout)
        self.assertIn("--force-recreate --no-deps --wait --wait-timeout 600 traefik", (self.root / "docker.log").read_text())

    def test_corrupted_payload_does_not_create_install(self):
        corrupted = self.script.replace(b"\nname: basicrum\n", b"\nname: damaged\n", 1)
        self.assertNotEqual(corrupted, self.script)
        result = self.run_installer(script=corrupted)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"checksum", result.stderr)
        self.assertFalse(self.dest.exists())

    def test_truncated_stream_never_starts_installation(self):
        for length in (len(self.script) // 2, self.script.index(b"  # End embedded file: start.sh\n")):
            with self.subTest(length=length):
                result = self.run_installer(script=self.script[:length])
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.dest.exists())
                self.assertFalse((self.root / "docker.log").exists())

    def test_managed_symlink_is_rejected(self):
        self.assert_ok(self.run_installer())
        outside = self.root / "outside"
        outside.write_text("untouched")
        (self.dest / "start.sh").unlink()
        (self.dest / "start.sh").symlink_to(outside)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"symlink", result.stderr)
        self.assertEqual(outside.read_text(), "untouched")

    def test_custom_tls_paths_are_relative_to_invocation(self):
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(self.root / "key.pem"), "-out", str(self.root / "cert.pem"),
            "-days", "1", "-subj", "/CN=localhost",
        ], check=True, capture_output=True, timeout=30)
        result = self.run_installer([
            "--domain", "localhost", "--tls", "custom", "--cert", "cert.pem",
            "--key=key.pem", "--no-start", "--yes",
        ])
        self.assert_ok(result)
        self.assertEqual((self.root / "key.pem").read_bytes(), (self.dest / "traefik/ssl/key.pem").read_bytes())

    def test_cloudflare_alias_requires_matching_origin_certificate(self):
        subprocess.run([
            "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", str(self.root / "origin.key"), "-out", str(self.root / "origin.pem"),
            "-days", "1", "-subj", "/CN=rum.example.com",
        ], check=True, capture_output=True, timeout=30)
        flags = ["--tls", "cloudflare", "--cert", "origin.pem", "--key", "origin.key",
                 "--no-start", "--yes"]
        self.assert_ok(self.run_installer(["--domain", "rum.example.com", *flags]))
        self.assertIn("TLS_MODE=custom", (self.dest / ".env").read_text())
        before = (self.dest / ".env").read_bytes()
        mismatch = self.run_installer(["--domain", "other.example.com", *flags])
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn(b"certificate does not cover other.example.com", mismatch.stderr)
        self.assertEqual((self.dest / ".env").read_bytes(), before)

    @unittest.skipUnless(REAL_DOCKER, "Docker CLI is needed for Compose validation")
    def test_real_compose_renders_expected_port_bindings(self):
        available = subprocess.run([REAL_DOCKER, "compose", "version"], capture_output=True, timeout=15)
        if available.returncode:
            self.skipTest("Docker Compose plugin is not available")
        # Docker Desktop can discover Compose through the user's CLI settings;
        # keep those while rendering only the isolated fixture's Compose files.
        compose_env = dict(self.env, HOME=os.environ["HOME"], PATH=os.environ["PATH"])
        cases = [
            (self.flags, "127.0.0.1", False),
            ([*self.flags, "--set", "HTTP_BIND="], None, False),
            (["--domain", "rum.example.com", "--tls", "letsencrypt", "--email", "admin@example.com",
              "--no-start", "--yes"], None, True),
        ]
        for flags, expected_host, https in cases:
            with self.subTest(flags=flags):
                self.assert_ok(self.run_installer(flags))
                result = subprocess.run([
                    REAL_DOCKER, "compose", "--project-directory", str(self.dest), "config", "--format", "json",
                ], cwd=self.dest, env=compose_env, capture_output=True, timeout=30)
                self.assert_ok(result)
                config = json.loads(result.stdout)
                ports = config["services"]["traefik"]["ports"]
                http = next(port for port in ports if port["target"] == 80)
                self.assertEqual(http.get("host_ip"), expected_host)
                self.assertEqual(any(port["target"] == 443 for port in ports), https)
                for service, repository in (
                    ("basicrum_backend", "backend_community"),
                    ("basicrum_beacon_service", "beacon_service_community"),
                    ("basicrum_frontend", "frontend_community"),
                ):
                    self.assertEqual(config["services"][service]["image"],
                                     f"basicrum/{repository}:{self.image_version}")
                self.assertEqual(set(config["services"]["traefik"]["networks"]), {"proxy"})
                for database in ("clickhouse", "basicrum_postgres"):
                    self.assertFalse(config["services"][database].get("ports"))
                    self.assertEqual(config["services"][database]["labels"]["traefik.enable"], "false")
                    self.assertEqual(set(config["services"][database]["networks"]), {"internal"})
                self.assertTrue(config["networks"]["internal"]["internal"])
                self.assertEqual(len(config["services"]), 6)

    @unittest.skipUnless(REAL_CURL, "curl is needed for the local HTTP check")
    def test_curl_pipeline_from_local_http_server(self):
        server = ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=self.build_dir.name))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/install.sh"
            result = subprocess.run([
                "bash", "-o", "pipefail", "-c", '"$1" -fsSL "$2" | bash -s -- "${@:3}"',
                "pipeline", REAL_CURL, url, *self.flags,
            ], cwd=self.root, env=self.env, capture_output=True, timeout=30)
            self.assert_ok(result)
            self.assertTrue((self.dest / ".env").exists())
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_plain_pipe_prompts_on_controlling_terminal(self):
        # No installer flags: exercise the exact interactive pipe experience.
        child, terminal = pty.fork()
        if child == 0:
            os.chdir(self.root)
            os.execvpe("bash", ["bash", "-c", 'cat "$1" | bash', "pipeline", str(self.installer)], self.env)
        transcript = b""
        responses = [(b"Public hostname of this Basicrum install", b"localhost\n"),
                     (b"Choice [1]:", b"4\n")]
        deadline = time.monotonic() + 30
        status = None
        try:
            while time.monotonic() < deadline:
                if select.select([terminal], [], [], 0.1)[0]:
                    try:
                        chunk = os.read(terminal, 65536)
                    except OSError:
                        chunk = b""
                    transcript += chunk
                    if responses and responses[0][0] in transcript:
                        os.write(terminal, responses.pop(0)[1])
                finished, child_status = os.waitpid(child, os.WNOHANG)
                if finished:
                    status = child_status
                    break
            self.assertIsNotNone(status, transcript.decode(errors="replace"))
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, transcript.decode(errors="replace"))
            self.assertFalse(responses, transcript.decode(errors="replace"))
            self.assertIn(b"Basicrum is ready", transcript)
            self.assertIn(b"curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash", transcript)
            self.assertIn("DOMAIN=localhost", (self.dest / ".env").read_text())
        finally:
            if status is None:
                os.kill(child, signal.SIGKILL)
                os.waitpid(child, 0)
            os.close(terminal)


if __name__ == "__main__":
    unittest.main()
