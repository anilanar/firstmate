#!/usr/bin/env bash
# Token-free installed-Codex guard for project-root directory trust. Uses a
# private PTY, throwaway HOME/CODEX_HOME, fake API credentials, and no prompt.
# Proves an unregistered linked worktree shows the directory dialog, accepting
# it writes the primary root, and the intake helper removes the same dialog.
# No fleet endpoint, real config, credentials, or hook trust store is touched.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_CODEX_TRUST_LIVE codex python3 node
TMP_ROOT=$(fm_test_tmproot fm-codex-trust-live)
VERSION=$(codex --version)
fm_git_worktree "$TMP_ROOT/project" "$TMP_ROOT/worktree" trust-live
python3 - "$TMP_ROOT" "$ROOT/bin/fm-codex-trust.sh" "$VERSION" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

root, helper, version = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
project, worktree = root / 'project', root / 'worktree'
config, user = root / 'codex', root / 'user'
config.mkdir()
user.mkdir()
store = config / 'config.toml'
base = 'check_for_update_on_startup = false\ncli_auth_credentials_store = "file"\n'
store.write_text(base)
(config / 'auth.json').write_text(json.dumps({'OPENAI_API_KEY': 'sk-firstmate-test-not-real'}))
env = dict(os.environ, HOME=str(user), CODEX_HOME=str(config), TERM='xterm-256color')
header = '[projects.' + json.dumps(str(project), ensure_ascii=False) + ']'
trust_dialog = re.compile(r'Do\s+you\s+trust\s+the\s+contents')
ready = re.compile(r'model:\s+(?!loading\b)[\w.-]+\s+/model')


def screen(data):
    text = data.decode('utf-8', errors='replace')
    text = re.sub(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', ' ', text)
    return re.sub(r'\x1b\[[0-9;? >]*[A-Za-z]', ' ', text)


def launch(expect_dialog, accept=False):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 45, 160, 0, 0))

    def own_terminal():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        ['codex', '--no-alt-screen', '--disable', 'hooks',
         '--dangerously-bypass-approvals-and-sandbox', '-C', str(worktree)],
        stdin=slave, stdout=slave, stderr=slave, env=env, preexec_fn=own_terminal,
    )
    os.close(slave)
    output = b''
    answered = False
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and process.poll() is None:
            if select.select([master], [], [], .1)[0]:
                chunk = os.read(master, 65536)
                output += chunk
                if b'\x1b[6n' in chunk:
                    os.write(master, b'\x1b[1;1R')
                if b'\x1b[c' in chunk:
                    os.write(master, b'\x1b[?1;2c')
            plain = screen(output)
            if trust_dialog.search(plain):
                if not expect_dialog:
                    raise AssertionError('registered root still showed the directory dialog')
                if not accept:
                    return
                if not answered:
                    # This consent is only for this test's own empty fixture.
                    os.write(master, b'\r')
                    answered = True
                if header in store.read_text() and 'trust_level = "trusted"' in store.read_text():
                    assert json.dumps(str(worktree)) not in store.read_text()
                    return
            if ready.search(plain) and not expect_dialog:
                return
        raise AssertionError('expected dialog or initialized composer never appeared: ' + screen(output)[-1500:])
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        os.close(master)


try:
    launch(True, accept=True)
    print('ok - codex ' + version + ': accepting a fresh worktree records trust at the primary root')
    launch(False)
    print('ok - codex ' + version + ': persisted root trust covers a later worktree session')
    store.write_text(base)
    subprocess.run([helper, '--project-add', str(project)], env=env, check=True, stdout=subprocess.DEVNULL)
    launch(False)
    print('ok - codex ' + version + ': intake registration reaches the composer without a directory dialog')
except (AssertionError, OSError, subprocess.SubprocessError) as error:
    print('not ok - codex ' + version + ': ' + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
