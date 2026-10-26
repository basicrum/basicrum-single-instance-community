#!/usr/bin/env python3
"""Exercise the built installer against real Docker in a disposable local project."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[1]
SERVICES = {
    'traefik', 'basicrum_backend', 'basicrum_frontend',
    'basicrum_beacon_service', 'basicrum_postgres', 'clickhouse',
}


def verify_installer(installer):
    digest = hashlib.sha256(installer.read_bytes()).hexdigest()
    expected = f'{digest}  {installer.name}\n'
    if installer.with_name(installer.name + '.sha256').read_text() != expected:
        raise RuntimeError('Installer checksum mismatch; rebuild before testing.')


def available_ports(count):
    sockets = []
    try:
        for _ in range(count):
            listener = socket.socket()
            listener.bind(('127.0.0.1', 0))
            sockets.append(listener)
        return [listener.getsockname()[1] for listener in sockets]
    finally:
        for listener in sockets:
            listener.close()


def check_health(output):
    rows = [line.split('|') for line in output.splitlines() if line]
    if len(rows) != len(SERVICES) or {row[0] for row in rows} != SERVICES:
        raise RuntimeError('Expected exactly the six Basicrum services.')
    for row in rows:
        if len(row) != 3 or row[1:] != ['running', 'healthy']:
            raise RuntimeError(f'Service did not become healthy: {row[0]}')


class SmokeTest:
    def __init__(self, installer, workspace):
        self.installer = installer
        self.directory = workspace / 'installation'
        self.project = 'basicrum-smoke-' + uuid.uuid4().hex[:16]
        # Keep Docker connection/auth settings, but no application overrides or
        # CI credentials. Compose must read only the fresh installation's .env.
        keep = {
            'PATH', 'HOME', 'TMPDIR', 'DOCKER_CONFIG', 'DOCKER_HOST', 'DOCKER_CONTEXT',
            'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH', 'DOCKER_API_VERSION',
            'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
            'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
        }
        self.env = {key: value for key, value in os.environ.items() if key in keep}
        self.env['COMPOSE_PROJECT_NAME'] = self.project
        self.secrets = set()

    def redact(self, text):
        env_file = self.directory / '.env'
        if env_file.exists():
            for line in env_file.read_text().splitlines():
                key, sep, value = line.partition('=')
                if sep and value and re.search(r'PASSWORD|SECRET|TOKEN_ENC_KEY', key):
                    self.secrets.add(value.strip('\"\''))
        for secret in sorted(self.secrets, key=len, reverse=True):
            if secret:
                text = text.replace(secret, '[redacted]')
        return text

    def run(self, args, *, timeout=60, show=False):
        process = subprocess.Popen(
            args, cwd=self.directory.parent, env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            start_new_session=True,
        )
        try:
            output, _ = process.communicate(timeout=timeout)
        except BaseException:
            # Stop the entire installer/Compose process group before cleanup.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                output, _ = process.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                output, _ = process.communicate()
            print(self.redact(output), flush=True)
            raise
        if show or process.returncode:
            print(self.redact(output), end='', flush=True)
        if process.returncode:
            raise RuntimeError(f'{args[0]} failed with exit code {process.returncode}')
        return output

    def compose(self, *args, **kwargs):
        return self.run([
            'docker', 'compose', '--project-name', self.project,
            '--project-directory', str(self.directory),
            '--env-file', str(self.directory / '.env'),
            '-f', str(self.directory / 'docker-compose.yml'), *args,
        ], **kwargs)

    def resources(self, kind):
        return self.run([
            'docker', kind, 'ls', '--quiet',
            *(['--all'] if kind == 'container' else []),
            '--filter', f'label=com.docker.compose.project={self.project}',
        ]).split()

    def assert_ready(self, port):
        containers = self.resources('container')
        if not containers:
            raise RuntimeError('No smoke-test containers were started.')
        health = self.run([
            'docker', 'inspect', '--format',
            '{{index .Config.Labels "com.docker.compose.service"}}|{{.State.Status}}|'
            '{{if .State.Health}}{{.State.Health.Status}}{{end}}', *containers,
        ])
        check_health(health)
        status = self.run([
            'curl', '--noproxy', '*', '--connect-timeout', '2', '--max-time', '10',
            '-fsS', '-o', '/dev/null', '-w', '%{http_code}',
            '--resolve', f'localhost:{port}:127.0.0.1',
            f'http://localhost:{port}/auth/login',
        ])
        if status != '200':
            raise RuntimeError(f'Login endpoint returned HTTP {status}.')
        print('All six services are healthy; login endpoint returns HTTP 200.', flush=True)

    def exercise(self, no_pull=False):
        http, clickhouse_http, clickhouse_native = available_ports(3)
        print(f'Smoke-test project: {self.project}; HTTP port: {http}', flush=True)
        print('Installing into a temporary directory with real Docker...', flush=True)
        self.run([
            'bash', str(self.installer), '--install-dir', str(self.directory),
            '--domain', 'localhost', '--tls', 'none', '--http-port', str(http),
            '--set', 'HTTP_BIND=127.0.0.1', '--set', f'COMPOSE_PROJECT_NAME={self.project}',
            '--set', f'CLICKHOUSE_HTTP_PORT={clickhouse_http}',
            '--set', f'CLICKHOUSE_NATIVE_PORT={clickhouse_native}', '--yes',
            *(['--no-pull'] if no_pull else []),
        ], timeout=1200, show=True)
        self.assert_ready(http)
        files = ['.env', 'traefik/traefik.yml']
        before = {name: (self.directory / name).read_bytes() for name in files}
        volumes = set(self.resources('volume'))
        if len(volumes) != 3:
            raise RuntimeError('Expected three isolated data/certificate volumes.')
        print('Re-running the installer to check configuration and volume preservation...', flush=True)
        self.run([
            'bash', str(self.installer), '--install-dir', str(self.directory),
            '--yes', '--no-pull',
        ], timeout=900, show=True)
        for name, contents in before.items():
            if (self.directory / name).read_bytes() != contents:
                raise RuntimeError(f'Re-running the installer changed {name}.')
        if set(self.resources('volume')) != volumes:
            raise RuntimeError('Re-running the installer changed the data volumes.')
        self.assert_ready(http)
        verify_installer(self.installer)

    def diagnostics(self):
        if (self.directory / '.env').exists():
            for args in [('ps', '--all'), ('logs', '--no-color', '--tail', '80')]:
                try:
                    self.compose(*args, show=True)
                except Exception as error:
                    print(f'Could not collect diagnostics: {error}', file=sys.stderr)

    def cleanup(self):
        # Use only this randomly named project's labels, even if installation
        # stopped before a complete .env existed. Never prune shared Docker data.
        errors = []
        for kind in ('container', 'network', 'volume'):
            try:
                resources = self.resources(kind)
                if resources:
                    self.run([
                        'docker', kind, 'rm',
                        *(['--force', '--volumes'] if kind == 'container' else []),
                        *resources,
                    ], timeout=120)
                if self.resources(kind):
                    raise RuntimeError(f'Smoke-test {kind} resources remain.')
            except Exception as error:
                errors.append(str(error))
        if errors:
            raise RuntimeError(f'Cleanup failed for {self.project}: ' + '; '.join(errors))
        print('Temporary containers, networks, volumes and installation files cleaned up.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--installer', type=Path, default=ROOT / 'dist/install.sh')
    parser.add_argument('--no-pull', action='store_true', help='Use cached images for a local rehearsal')
    args = parser.parse_args()
    installer = args.installer.resolve()
    verify_installer(installer)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    with tempfile.TemporaryDirectory(prefix='basicrum-smoke-') as temporary:
        test = SmokeTest(installer, Path(temporary).resolve())
        try:
            test.exercise(no_pull=args.no_pull)
        except BaseException:
            test.diagnostics()
            raise
        finally:
            test.cleanup()
    print('Real Docker installer smoke test passed.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('Smoke test interrupted.', file=sys.stderr)
        sys.exit(130)
    except Exception as error:
        print(f'Smoke test failed: {error}', file=sys.stderr)
        sys.exit(1)
