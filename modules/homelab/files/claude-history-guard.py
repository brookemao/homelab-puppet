#!/usr/bin/python3
"""Stop iapark's immich-tools devcontainer after today's overnight Claude use."""

from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import subprocess
import sys
from zoneinfo import ZoneInfo

HISTORY = Path('/home/iapark/.local/share/containers/storage/volumes/claude-home/_data/history.jsonl')
TIMEZONE = 'America/Vancouver'


def latest_record(path):
    """Read only the last nonempty JSONL record, including large messages."""
    with path.open('rb') as stream:
        position = stream.seek(0, 2)
        remainder = b''
        while position:
            size = min(position, 8192)
            position -= size
            stream.seek(position)
            lines = (stream.read(size) + remainder).split(b'\n')
            remainder = lines[0]
            candidates = lines[1:] if position else lines
            for line in reversed(candidates):
                if line.strip():
                    # A partial/invalid last record must never fall back to
                    # an older message and incorrectly stop a container.
                    return json.loads(line)
    return None


def message_time(record):
    value = record.get('timestamp') if isinstance(record, dict) else None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if not math.isfinite(value):
            return None
        # Claude history uses Unix milliseconds; accept seconds as well.
        seconds = value / 1000 if abs(value) >= 100_000_000_000 else value
        return datetime.fromtimestamp(seconds, timezone.utc)
    if isinstance(value, str):
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return parsed if parsed.tzinfo is not None else None
    return None


def is_today_overnight(record, now):
    if now.hour >= 9:
        return False
    try:
        timestamp = message_time(record)
        if timestamp is None:
            return False
        local = timestamp.astimezone(now.tzinfo)
        return local.date() == now.date() and local.hour < 9 and local <= now
    except (ValueError, OverflowError, OSError):
        return False


def is_immich_tools(container):
    names = container.get('names') or []
    if isinstance(names, str):
        names = [names]
    if any(name == 'immich-tools' or name.startswith('vsc-immich-tools-') for name in names):
        return True
    labels = container.get('labels') or {}
    for key in ('devcontainer.local_folder', 'vsch.local.folder'):
        folder = labels.get(key, '').replace('\\', '/').rstrip('/')
        if folder.rsplit('/', 1)[-1] == 'immich-tools':
            return True
    return False


def podman(*args):
    # The systemd service runs as iapark, so this accesses only that user's
    # existing rootless storage. Never use a configured remote connection.
    env = dict(os.environ, HOME='/home/iapark', XDG_RUNTIME_DIR=f'/run/user/{os.getuid()}')
    return subprocess.run(
        ['/usr/bin/podman', '--remote=false', *args], env=env,
        text=True, stdout=subprocess.PIPE, check=True, timeout=45,
    ).stdout


def enforce(path=HISTORY, now=None):
    now = now if now is not None else datetime.now(ZoneInfo(TIMEZONE))
    if now.hour >= 9:
        return
    try:
        record = latest_record(path)
    except FileNotFoundError:
        return
    except (json.JSONDecodeError, UnicodeDecodeError):
        print('Ignoring incomplete or invalid latest history record.', flush=True)
        return
    if not is_today_overnight(record, now):
        return
    containers = json.loads(podman('ps', '--format', 'json'))
    targets = []
    for item in containers:
        container = {key.lower(): value for key, value in item.items()}
        if is_immich_tools(container):
            targets.append(container['id'])
    if targets:
        print(f'Overnight Claude activity: stopping {len(targets)} immich-tools container(s).', flush=True)
        podman('stop', '--time', '10', *targets)
    else:
        print('Overnight Claude activity: no running immich-tools devcontainer found.', flush=True)


if __name__ == '__main__':
    try:
        enforce()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f'Claude history guard failed: {error}')
