#!/usr/bin/env python3
"""Check a built layout and stage the real installer without root or host changes.

Run for both layouts (the runtime prefix and output directory are independent):
  zig build
  python3 tests/install_layout.py zig-out /usr/local
  zig build -Dinstall-prefix=/usr --prefix zig-out/package
  python3 tests/install_layout.py zig-out/package /usr
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def check(tree, prefix):
    bindir = prefix.rstrip('/') + '/bin'
    assert tree.joinpath('install-prefix').read_text().strip().rstrip('/') == prefix.rstrip('/')
    for name, command in [('rediwm-dm', 'rediwm --greeter'),
                          ('rediwm-restart', 'rediwm'),
                          ('rediwm', 'rediwm-accounts-helper')]:
        assert f'{bindir}/{command}'.encode() in (tree / 'bin' / name).read_bytes(), name

    with tempfile.TemporaryDirectory(prefix='rediwm-install-') as directory:
        stage = Path(directory)
        env = dict(os.environ, DESTDIR=directory)
        command = ['sh', str(ROOT / 'scripts/install-session-root.sh'), str(ROOT), str(tree), 'yes']
        subprocess.run(command, env=env, check=True)
        installed_bin = stage / bindir.lstrip('/')
        assert (installed_bin / 'rediwm-restart').is_file()
        assert not list(installed_bin.glob('.rediwm-install.*'))
        for path in (tree / 'share').rglob('*.desktop'):
            text = path.read_text()
            assert '@BINDIR@' not in text
            for line in text.splitlines():
                if line.startswith(('Exec=', 'TryExec=')):
                    executable = line.split('=', 1)[1].split()[0]
                    assert executable.startswith(bindir + '/'), (path, executable)
                    assert (stage / executable.lstrip('/')).is_file(), executable
        policy = stage / 'usr/share/polkit-1/actions/org.rediwm.accounts.policy'
        annotation = ET.parse(policy).find('.//annotate')
        assert annotation.text == f'{bindir}/rediwm-accounts-helper'
        service = stage / 'usr/lib/systemd/system/rediwm-dm.service'
        assert f'ExecStart={bindir}/rediwm-dm\n' in service.read_text()
        config = stage / 'etc/rediwm/dm.conf'
        assert f'greeter_command = {bindir}/rediwm --greeter' in config.read_text()
        for path in stage.rglob('*'):
            if path.is_file() and path.suffix in ('.desktop', '.service', '.conf', '.policy'):
                contents = path.read_text()
                assert '@BINDIR@' not in contents, path
                assert directory not in contents, path
                if prefix != '/usr/local':
                    assert '/usr/local/bin/rediwm' not in contents, path
        # Updates must preserve an administrator's DM configuration.
        config.write_text('greeter_command = /custom/greeter\n')
        subprocess.run(command, env=env, check=True)
        assert config.read_text() == 'greeter_command = /custom/greeter\n'
    print(f'PASS: generated files, runtime paths and staged installation for {prefix}')


if __name__ == '__main__':
    check(Path(sys.argv[1]).resolve(), sys.argv[2])
