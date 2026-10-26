"""Check failure detection and isolation in the real-Docker smoke-test runner."""

from contextlib import redirect_stdout
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'smoke_installer', Path(__file__).resolve().parents[1] / 'scripts/smoke-installer.py',
)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class SmokeRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.installer = self.root / 'install.sh'
        self.installer.write_text('#!/usr/bin/env bash\nexit 0\n')
        digest = hashlib.sha256(self.installer.read_bytes()).hexdigest()
        self.installer.with_name('install.sh.sha256').write_text(f'{digest}  install.sh\n')
        self.runner = smoke.SmokeTest(self.installer, self.root)
        self.runner.directory.mkdir()

    def test_corrupt_installer_is_rejected_before_execution(self):
        smoke.verify_installer(self.installer)
        self.installer.write_text('exit 1\n')
        with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'):
            smoke.verify_installer(self.installer)

    def test_health_requires_every_service_running_and_healthy(self):
        healthy = '\n'.join(f'{service}|running|healthy' for service in sorted(smoke.SERVICES))
        smoke.check_health(healthy)
        for broken in (
            healthy.replace('|healthy', '|starting', 1),
            healthy.replace('|running', '|exited', 1),
            healthy.rsplit('\n', 1)[0],
            healthy + '\ntraefik|running|healthy',
            healthy.replace('traefik|', 'unrelated|'),
        ):
            with self.subTest(output=broken), self.assertRaises(RuntimeError):
                smoke.check_health(broken)

    def test_compose_overrides_and_ci_credentials_are_not_inherited(self):
        with patch.dict(os.environ, {
            'COMPOSE_FILE': '/unrelated/compose.yml', 'COMPOSE_PROJECT_NAME': 'production',
            'POSTGRES_PASSWORD': 'production-secret', 'GH_TOKEN': 'ci-secret',
        }):
            runner = smoke.SmokeTest(self.installer, self.root)
        self.assertNotIn('COMPOSE_FILE', runner.env)
        self.assertNotIn('POSTGRES_PASSWORD', runner.env)
        self.assertNotIn('GH_TOKEN', runner.env)
        self.assertEqual(runner.env['COMPOSE_PROJECT_NAME'], runner.project)
        self.assertNotEqual(runner.project, 'production')

    def test_diagnostics_redact_both_original_and_replaced_secrets(self):
        env = self.runner.directory / '.env'
        env.write_text('POSTGRES_PASSWORD=original-password\nORG_TOKEN_ENC_KEY_V1=encoded-key\n')
        self.assertEqual(self.runner.redact('original-password encoded-key'), '[redacted] [redacted]')
        env.write_text('POSTGRES_PASSWORD=new-password\n')
        self.assertEqual(self.runner.redact('original-password new-password'), '[redacted] [redacted]')

    def test_rerun_configuration_change_fails_the_smoke_test(self):
        installs = 0

        def install(*args, **kwargs):
            nonlocal installs
            installs += 1
            (self.runner.directory / '.env').write_text(f'JWT_SECRET=secret-{installs}\n')
            (self.runner.directory / 'traefik').mkdir(exist_ok=True)
            (self.runner.directory / 'traefik/traefik.yml').write_text('ping: {}\n')

        with patch.object(self.runner, 'run', side_effect=install), \
                patch.object(self.runner, 'assert_ready'), \
                patch.object(self.runner, 'resources', return_value=['v1', 'v2', 'v3']), \
                redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, 'changed .env'):
                self.runner.exercise()

    def test_cleanup_removes_only_resources_selected_by_its_project_label(self):
        seen = []
        remaining = {'container': ['test-container'], 'network': ['test-network'], 'volume': ['test-volume']}

        def docker(args, **kwargs):
            seen.append(args)
            kind, operation = args[1:3]
            if operation == 'ls':
                self.assertEqual(args[-2:], [
                    '--filter', f'label=com.docker.compose.project={self.runner.project}',
                ])
                return '\n'.join(remaining[kind])
            self.assertEqual(operation, 'rm')
            self.assertEqual(args[-1], remaining[kind][0])
            remaining[kind] = []
            return ''

        with patch.object(self.runner, 'run', side_effect=docker), redirect_stdout(io.StringIO()):
            self.runner.cleanup()
        self.assertFalse(any(remaining.values()))
        self.assertFalse(any('prune' in args for args in seen))

    def test_cleanup_failure_is_fatal_but_other_resource_types_are_attempted(self):
        attempted = []

        def resources(kind):
            attempted.append(kind)
            if kind == 'container':
                raise RuntimeError('Docker unavailable')
            return []

        with patch.object(self.runner, 'resources', side_effect=resources):
            with self.assertRaisesRegex(RuntimeError, 'Cleanup failed'):
                self.runner.cleanup()
        self.assertIn('network', attempted)
        self.assertIn('volume', attempted)
