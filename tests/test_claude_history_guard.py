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
        self.state.mkdir()
        self.log = self.root / 'calls'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        CALLS=str(self.log), TEST_DAY='2026-10-20', TEST_HOUR='01',
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
            str(self.projects)).replace('/var/lib/homelab-claude-history', str(self.state))
        self.guard = self.root / 'guard.sh'
        self.guard.write_text(source)
        self.access = self.root / 'access.sh'
        self.access.write_text((FILES / 'access-hours.sh').read_text().replace(
            '/var/lib/homelab-claude-history', str(self.state)))

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

    def test_old_and_exact_midnight_do_not_kill(self):
        for timestamp in ('2026-10-19T23:59:59-07:00', '2026-10-20T07:00:00Z'):
            self.records(timestamp)
            self.assertEqual(self.run_script(), '')

    def test_latest_first_fractional_and_once_per_night(self):
        self.records('2026-10-20T07:00:00.001Z', '2026-10-19T20:00:00Z')
        calls = self.run_script()
        self.assertIn('-u iapark -- env HOME=/home/iapark XDG_RUNTIME_DIR=/run/user/1000', calls)
        self.assertIn('--remote=false kill target', calls)
        self.assertIn('disable --runtime --now homelab-claude-history.timer', calls)
        self.assertTrue((self.state / 'killed-2026-10-20').exists())
        self.log.unlink()
        self.assertNotIn('runuser', self.run_script())
        self.assertNotIn('enable --runtime --now', self.run_script(self.access))
        self.env['TEST_DAY'] = '2026-10-21'
        self.log.unlink()
        self.assertIn('enable --runtime --now homelab-claude-history.timer',
                      self.run_script(self.access))

    def test_daytime_guard_and_timer_disable(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['TEST_HOUR'] = '09'
        self.assertEqual(self.run_script(), '')
        self.assertIn('disable --runtime --now homelab-claude-history.timer',
                      self.run_script(self.access))

    def test_no_target_keeps_checking(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['CONTAINERS'] = '[{"Id":"other","Names":["immich"]}]'
        calls = self.run_script()
        self.assertNotIn(' kill ', calls)
        self.assertNotIn('systemctl', calls)
        self.assertFalse(any(self.state.iterdir()))

    def test_devcontainer_names_and_labels(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['CONTAINERS'] = json.dumps([
            {'id': 'name', 'names': 'vsc-immich-tools-abc'},
            {'id': 'label', 'labels': {'devcontainer.local_folder': '/work/immich-tools/'}},
            {'id': 'windows', 'labels': {'vsch.local.folder': r'C:\work\immich-tools'}},
            {'id': 'unrelated', 'names': ['immich']},
        ])
        self.assertIn('kill name label windows', self.run_script())

    def test_kill_failure_does_not_disable_or_mark(self):
        self.records('2026-10-20T08:00:00Z')
        self.env['KILL_STATUS'] = '1'
        self.assertNotIn('systemctl', self.run_script(success=False))
        self.assertFalse(any(self.state.iterdir()))

    def test_malformed_json_and_timestamp_fail_without_kill(self):
        (self.projects / 'broken.jsonl').write_text('{"origin":{"kind":"human"}\n')
        self.assertEqual(self.run_script(success=False), '')
        (self.projects / 'broken.jsonl').unlink()
        self.records('not-a-timestamp')
        self.assertEqual(self.run_script(success=False), '')
