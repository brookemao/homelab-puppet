"""Linux integration checks using real Bash/jq/date and mocked system controls.

Run: python3 -m unittest discover -s tests -v
Requires bash, jq and GNU date. No real containers or system units are touched.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


FILES = Path(__file__).resolve().parents[1] / 'modules/homelab/files'


class ClaudeGuardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.projects = self.root / 'projects'
        self.projects.mkdir()
        self.state = self.root / 'state'
        self.marker = self.state / 'last-killed-message'
        self.log = self.root / 'calls'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        CALLS=str(self.log), STATE_DIRECTORY=str(self.state),
                        TEST_DAY='2026-10-20', TEST_HOUR='01',
                        CONTAINERS=json.dumps([{'Id': 'target', 'Names': ['immich-tools']}]))
        self.command('date', '''case "$*" in
            +%F) echo "$TEST_DAY" ;;
            +%H) echo "$TEST_HOUR" ;;
            *) exec /usr/bin/date "$@" ;;
        esac''')
        self.command('systemctl', '''echo "systemctl $*" >> "$CALLS"
            case "$1" in
                show) echo not-found ;;
                is-enabled) exit 1 ;;
            esac''')
        self.command('id', 'echo 1000')
        self.command('runuser', '''echo "runuser $*" >> "$CALLS"
            case "$*" in
                *' ps --format json') echo "$CONTAINERS" ;;
                *' kill '*) exit "${KILL_STATUS:-0}" ;;
                *) exit 99 ;;
            esac''')
        source = (FILES / 'claude-history-guard.sh').read_text()
        source = source.replace(
            '/home/iapark/.local/share/containers/storage/volumes/claude-home/_data/projects',
            str(self.projects))
        self.guard = self.root / 'guard.sh'
        self.guard.write_text(source)
        self.access = self.root / 'access.sh'
        self.access.write_text((FILES / 'access-hours.sh').read_text())

    def command(self, name, source):
        path = self.bin / name
        path.write_text('#!/bin/bash\nset -eu\n' + source + '\n')
        path.chmod(0o755)

    def records(self, *timestamps):
        nested = self.projects / 'nested'
        nested.mkdir(exist_ok=True)
        (nested / 'session.jsonl').write_text(''.join(
            json.dumps({'origin': {'kind': 'human'}, 'timestamp': timestamp},
                       separators=(',', ':')) + '\n' for timestamp in timestamps))

    def run_script(self, path=None, success=True):
        result = subprocess.run(['bash', str(path or self.guard)], env=self.env,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return self.log.read_text() if self.log.exists() else ''

    def test_no_humans(self):
        (self.projects / 'assistant.jsonl').write_text(
            '{"origin":{"kind":"assistant"},"timestamp":"2026-10-20T08:00:00Z"}\n')
        self.assertEqual(self.run_script(), '')

    def test_old_and_exact_window_start_do_not_kill(self):
        for timestamp in ('2026-10-19T22:59:59-07:00', '2026-10-20T06:00:00Z'):
            self.records(timestamp)
            self.assertEqual(self.run_script(), '')

    def test_latest_first_fractional_and_deduplicated_kills(self):
        self.records('2026-10-20T06:00:00.001Z', '2026-10-19T20:00:00Z')
        calls = self.run_script()
        self.assertIn('-u iapark -- env HOME=/home/iapark XDG_RUNTIME_DIR=/run/user/1000', calls)
        self.assertIn('--remote=false kill target', calls)
        self.assertNotIn('systemctl', calls)
        self.assertEqual(self.marker.read_text(), '2026-10-20T06:00:00.001Z\n')
        self.log.unlink()
        # A restarted container is left alone until a new prompt appears.
        self.assertEqual(self.run_script(), '')
        self.records('2026-10-20T06:00:00.002Z', '2026-10-20T06:00:00.001Z')
        self.assertIn('--remote=false kill target', self.run_script())
        self.assertEqual(self.marker.read_text(), '2026-10-20T06:00:00.002Z\n')
        self.log.unlink()
        self.assertEqual(self.run_script(), '')

    def test_saved_timestamp_survives_separate_runs(self):
        self.records('2026-10-20T08:00:00Z')
        self.state.mkdir()
        self.marker.write_text('2026-10-20T08:00:00Z\n')
        self.assertEqual(self.run_script(), '')

    def test_previous_nights_activity_does_not_kill(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['TEST_DAY'] = '2026-10-21'
        self.assertEqual(self.run_script(), '')

    def test_evening_cutoff(self):
        self.env['TEST_HOUR'] = '23'
        self.records('2026-10-20T22:59:59-07:00')
        self.assertEqual(self.run_script(), '')
        self.records('2026-10-20T23:00:00.001-07:00')
        self.assertIn('--remote=false kill target', self.run_script())

    def test_before_evening_window_is_inactive(self):
        self.env['TEST_HOUR'] = '22'
        self.records('2026-10-20T22:30:00-07:00')
        self.assertEqual(self.run_script(), '')

    def test_daytime_guard(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['TEST_HOUR'] = '09'
        self.assertEqual(self.run_script(), '')

    def test_access_hours_only_controls_ssh_and_cockpit(self):
        for hour in ('00', '08', '09', '22', '23'):
            with self.subTest(hour=hour):
                self.env['TEST_HOUR'] = hour
                self.log.unlink(missing_ok=True)
                calls = self.run_script(self.access)
                self.assertNotIn('claude', calls)
                if int(hour) < 9:
                    self.assertIn('mask --runtime --now cockpit.socket cockpit.service sshd.service', calls)
                    self.assertNotIn('systemctl start', calls)
                else:
                    self.assertNotIn('mask --runtime --now', calls)
                    self.assertIn('start cockpit.socket sshd.service', calls)

    def test_no_target_keeps_checking(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['CONTAINERS'] = '[{"Id":"other","Names":["immich"]}]'
        calls = self.run_script()
        self.assertNotIn(' kill ', calls)
        self.assertNotIn('systemctl', calls)
        self.assertFalse(self.marker.exists())
        self.env['CONTAINERS'] = '[{"Id":"target","Names":["immich-tools"]}]'
        self.log.unlink()
        self.assertIn('--remote=false kill target', self.run_script())
        self.assertEqual(self.marker.read_text(), '2026-10-20T08:00:00Z\n')

    def test_devcontainer_names_and_labels(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['CONTAINERS'] = json.dumps([
            {'id': 'name', 'names': 'vsc-immich-tools-abc'},
            {'id': 'label', 'labels': {'devcontainer.local_folder': '/work/immich-tools/'}},
            {'id': 'windows', 'labels': {'vsch.local.folder': r'C:\work\immich-tools'}},
            {'id': 'unrelated', 'names': ['immich']},
        ])
        self.assertIn('kill name label windows', self.run_script())

    def test_kill_failure_keeps_checking(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['KILL_STATUS'] = '1'
        self.assertNotIn('systemctl', self.run_script(success=False))
        self.assertFalse(self.marker.exists())
        self.log.unlink()
        self.env['KILL_STATUS'] = '0'
        self.assertIn('--remote=false kill target', self.run_script())
        self.assertEqual(self.marker.read_text(), '2026-10-20T08:00:00Z\n')

    def test_failed_kill_preserves_previous_prompt_timestamp(self):
        self.records('2026-10-20T08:00:00Z')
        self.state.mkdir()
        self.marker.write_text('2026-10-20T07:00:00Z\n')
        self.env['KILL_STATUS'] = '1'
        self.run_script(success=False)
        self.assertEqual(self.marker.read_text(), '2026-10-20T07:00:00Z\n')

    def test_malformed_json_and_timestamp_fail_without_kill(self):
        (self.projects / 'broken.jsonl').write_text('{"origin":{"kind":"human"}\n')
        self.assertEqual(self.run_script(success=False), '')
        (self.projects / 'broken.jsonl').unlink()
        self.records('not-a-timestamp')
        self.assertEqual(self.run_script(success=False), '')
