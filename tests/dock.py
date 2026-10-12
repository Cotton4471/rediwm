#!/usr/bin/env python3
"""Optional dock: settings persistence, input, window lifecycle and scaling."""
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib

from PIL import Image, ImageChops
from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def run():
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        process, log = spawn_compositor(tmp, scale=scale, outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'), config_content='''[compositor]
xwayland = false
[animations]
enabled = false
''', env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
               'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
               'XDG_CACHE_HOME': str(tmp / 'cache'), 'REDIWM_FILES_DEVICES': '0'})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                def dock():
                    return ui.widgets('dock')
                def button(name):
                    return next(w for w in dock() if w['name'] == name)
                def center(widget):
                    b = widget['global_box']
                    return round(b['x'] + b['width'] / 2), round(b['y'] + b['height'] / 2)
                def click(widget):
                    ipc.click_at(*center(widget))
                    ipc.wait_for_frame()
                def shot(name):
                    path = tmp / (name + '.png')
                    ipc.screenshot(str(path))
                    with Image.open(path) as image:
                        return image.convert('RGB')
                assert not dock(), 'dock must default off'
                ipc.action('open_control_center')
                ipc.wait_for_panel_settled('control_center')
                click(ui.find('Appearance', panel='control_center'))
                toggle = ui.scroll_into_view('dock_enabled')
                assert toggle['on'] is False
                click(toggle)
                wait_for(dock, 'dock enabled')
                assert tomllib.loads((tmp / 'rediwm-config.toml').read_text())['compositor']['dock_enabled']
                click(ui.scroll_into_view('dock_enabled'))
                wait_for(lambda: not dock(), 'dock disabled')
                assert not tomllib.loads((tmp / 'rediwm-config.toml').read_text())['compositor']['dock_enabled']
                click(ui.scroll_into_view('dock_enabled'))
                wait_for(dock, 'dock enabled again')
                ipc.action('close_panel', {'panel': 'control_center'})
                ipc.wait_for_frame()
                assert ipc.get_shell_state()['taskbars'], 'dock must coexist with taskbar'
                assert ipc.hit_test(*center(button('terminal')))['target_type'] == 'dock'
                ipc.move_cursor(5, 5)
                plain = shot('plain')
                ipc.move_cursor(*center(button('terminal')))
                ipc.wait_for_frame()
                hover = shot('hover')
                assert ImageChops.difference(plain, hover).getbbox(), 'no hover feedback'
                # Leaving in one jump unhovers the dock; motion elsewhere then paints nothing.
                ipc.move_cursor(5, 5)
                ipc.wait_for_frame()
                def panel_bytes():
                    perf = ipc.get_perf()
                    return perf['panel_allocated_bytes'] + perf['panel_reused_bytes']
                painted = panel_bytes()
                for x in range(40, 60):
                    ipc.move_cursor(x, 40)
                ipc.wait_for_frame()
                assert panel_bytes() == painted, 'motion off the dock repaints it'
                if preview := os.environ.get('REDIWM_DOCK_PREVIEW'):
                    hover.save(preview)
                click(button('applications'))
                wait_for(lambda: ipc.get_shell_state()['start_menu'], 'dock launcher')
                ipc.action('close_panel', {'panel': 'start_menu'})
                ipc.wait_for_frame()
                click(button('settings'))
                wait_for(lambda: ipc.get_shell_state()['control_center'], 'dock settings')
                ipc.action('close_panel', {'panel': 'control_center'})
                ipc.wait_for_frame()
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock')), None), 'display')
                clients.append(subprocess.Popen([str(tmp / 'client'), '--app-id', 'dock.test', '--title', 'Dock test'],
                    env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                win = wait_for(lambda: next((w for w in ipc.get_windows() if w['app_id'] == 'dock.test'), None), 'test window')
                wid = win['id']
                name = f'window_{wid}'
                wait_for(lambda: any(w['name'] == name for w in dock()), 'window in dock')
                ipc.wait_for('window_geometry_settled', window_id=wid)
                click(button(name))
                wait_for(lambda: next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'dock minimize')
                click(button(name))
                wait_for(lambda: not next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'dock restore')
                assert ipc.get_focused_window()['id'] == wid
                fullscreen_point = center(button(name))
                ipc.action('fullscreen_window', {'id': wid})
                wait_for(lambda: not dock(), 'fullscreen hides dock')
                # Fullscreen on one monitor must leave the other dock visible.
                for bar in ipc.get_shell_state()['taskbars']:
                    b = bar['box']
                    x, y = b['x'] + b['width'] // 2, b['y'] - 40
                    if not b['x'] <= fullscreen_point[0] < b['x'] + b['width']:
                        assert ipc.hit_test(x, y)['target_type'] == 'dock'
                ipc.action('fullscreen_window', {'id': wid})
                wait_for(dock, 'leave fullscreen restores dock')
                ipc.move_cursor(*center(button(name)))
                ipc.action('close_window', {'id': wid})
                wait_for(lambda: not any(w['name'] == name for w in dock()), 'closed hovered window removed')
                if os.environ.get('REDIWM_DOCK_OVERFLOW'):
                    capacity = (ipc.get_outputs()[0]['logical_width'] - 40) // 56 - 4
                    for index in range(capacity + 2):
                        clients.append(subprocess.Popen([str(tmp / 'client'), '--app-id', f'dock.overflow{index}'],
                            env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                    wait_for(lambda: len(ipc.get_windows()) == capacity + 2, 'overflow windows')
                    ipc.wait_for_frame()
                    def shown():
                        return {w['name'] for w in dock() if (w['name'] or '').startswith('window_')}
                    first = shown()
                    assert len(first) == capacity
                    ipc.move_cursor(*center(button('terminal')))
                    # Poll: with two outputs the next frame may be the other output's.
                    ipc.scroll(0, -120)
                    try:
                        wait_for(lambda: shown() != first, 'scroll', timeout=2)
                    except AssertionError:
                        ipc.scroll(0, 120)
                        wait_for(lambda: shown() != first, 'overflow windows cannot be reached')
                    for client in clients:
                        stop_process(client)
                    wait_for(lambda: not ipc.get_windows(), 'overflow cleanup')
                    wait_for(lambda: not shown(), 'closed windows left in the dock')
                # Config reload relocates the dock above a bottom taskbar only.
                cfg = tmp / 'rediwm-config.toml'
                before = button('terminal')['global_box']['y']
                cfg.write_text(cfg.read_text().replace('[compositor]', '[compositor]\ntaskbar_position = "top"'))
                ipc.reload_config()
                wait_for(lambda: button('terminal')['global_box']['y'] > before, 'dock moved down')
                x, y = center(button('terminal'))
                cfg.write_text(cfg.read_text().replace('dock_enabled = true', 'dock_enabled = false'))
                ipc.reload_config()
                wait_for(lambda: not dock(), 'reload disables dock')
                assert ipc.hit_test(x, y)['target_type'] != 'dock', 'disabled dock intercepts input'
            print(f'PASS: dock defaults, Appearance, persistence, hover, launcher, settings, windows, fullscreen, reload ({scale}x)')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == '__main__':
    run()
