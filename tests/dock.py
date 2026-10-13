#!/usr/bin/env python3
"""Optional dock: settings persistence, input, window lifecycle and scaling."""
import os
import signal
import shutil
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
        applications = tmp / 'data' / 'applications'
        applications.mkdir(parents=True)
        for name, app_id, category in (
            ('dock-files', 'dock.files.running', 'FileManager'),
            ('dock-terminal', 'dock.terminal.running', 'TerminalEmulator'),
        ):
            (applications / f'{name}.desktop').write_text(
                f'[Desktop Entry]\nType=Application\nName={name}\nStartupWMClass={app_id}\n'
                f'Categories={category};\nExec={tmp / "client"} --app-id {app_id}\n')
        fallback = tmp / 'fallback-terminal'
        shutil.copyfile(tmp / 'client', fallback)
        fallback.chmod(0o700)
        (applications / 'fallback.desktop').write_text(
            '[Desktop Entry]\nType=Application\nName=Fallback\nStartupWMClass=dock.fallback\n'
            f'Categories=TerminalEmulator;\nExec={fallback} --app-id dock.fallback\n')
        process, log = spawn_compositor(tmp, scale=scale, outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'), config_content='''[compositor]
xwayland = false
default_file_manager = "dock-files.desktop"
default_terminal = "dock-terminal.desktop"
[animations]
enabled = false
''', env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
               'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
               'XDG_DATA_DIRS': str(tmp / 'empty'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
               'TERMINAL': f'"{fallback}" --app-id dock.fallback', 'REDIWM_FILES_DEVICES': '0'})
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
                def pill(name, screenshot):
                    ipc.move_cursor(5, 5)
                    ipc.wait_for_frame()
                    b = button(name)['global_box']
                    root = dock()[0]['global_box']
                    x, y = b['x'] + b['width'] / 2, b['y'] + b['height'] + 1
                    return shot(screenshot).crop(tuple(round(v * scale) for v in
                        (x - 12, y, x + 12, root['y'] + root['height'] - 2)))
                def shortcuts_only():
                    return {w['name'] for w in dock() if w['name']} == {'applications', 'files', 'terminal', 'settings'}
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
                slider = ui.scroll_into_view('dock_height')
                assert (slider['min'], slider['max'], slider['step'], slider['value']) == (48, 96, 2, 68)
                root = dock()[0]['global_box']
                bottom = root['y'] + root['height']
                for height in (48, 96, 68):
                    slider = ui.scroll_into_view('dock_height')
                    area = slider['global_box']
                    fraction = (height - 48) / 48
                    for _ in range(3):
                        point = (round(area['x'] + min(area['width'] - 1, area['width'] * fraction)),
                                 round(area['y'] + area['height'] / 2))
                        if ipc.hit_test(*point)['target_type'] != 'dock':
                            break
                        # A large dock can cover the bottom of the Settings
                        # window. Scroll the control farther up before clicking.
                        viewport = next(w['global_box'] for w in ui.widgets('control_center') if w['role'] == 'scroll_container')
                        ipc.move_cursor(viewport['x'] + viewport['width'] - 8, viewport['y'] + 40)
                        ipc.scroll(0, -130)
                        previous_y = area['y']
                        wait_for(lambda: ui.find('dock_height', panel='control_center')['global_box']['y'] < previous_y, 'slider scrolled above dock')
                        area = ui.scroll_into_view('dock_height')['global_box']
                    ipc.click_at(*point)
                    wait_for(lambda: dock()[0]['global_box']['height'] == height,
                             f'dock height changed live to {height}: slider={ui.find("dock_height", panel="control_center")["value"]}, dock={dock()[0]["global_box"]}')
                    assert tomllib.loads((tmp / 'rediwm-config.toml').read_text())['compositor']['dock_height'] == height
                    root = dock()[0]['global_box']
                    assert root['y'] + root['height'] == bottom, 'resize moved the dock bottom'
                    for item in (w for w in dock() if w['name']):
                        box = item['global_box']
                        assert 30 <= box['height'] <= 68 and box['width'] == box['height']
                        assert root['x'] <= box['x'] and box['x'] + box['width'] <= root['x'] + root['width']
                        assert root['y'] <= box['y'] and box['y'] + box['height'] < bottom
                        assert ipc.hit_test(*center(item))['target_type'] == 'dock'
                    if height == 96:
                        ipc.action('close_panel', {'panel': 'control_center'})
                        ipc.action('open_appearance')
                        ipc.wait_for_panel_settled('control_center')
                        assert ui.scroll_into_view('dock_height')['value'] == 96
                ipc.action('close_panel', {'panel': 'control_center'})
                ipc.wait_for_frame()
                assert ipc.get_shell_state()['taskbars'], 'dock must coexist with taskbar'
                assert ipc.hit_test(*center(button('terminal')))['target_type'] == 'dock'
                ipc.move_cursor(5, 5)
                # The dock's raster and glass mask follow the window radius,
                # including a live reload back to a previously painted shape.
                cfg = tmp / 'rediwm-config.toml'
                original = cfg.read_text()
                corners = []
                for index, radius in enumerate((0, 24, 0)):
                    cfg.write_text(original + f'\n[theme]\nradius_lg = {radius}\n')
                    ipc.reload_config()
                    ipc.wait_for_frame()
                    box = button('applications')['global_box']
                    x, y = box['x'] - 12, box['y'] - 8
                    corners.append(shot(f'radius-{index}').crop(tuple(round(v * scale) for v in
                        (x, y, x + 8, y + 8))))
                assert ImageChops.difference(corners[0], corners[1]).getbbox(), 'dock ignores window radius'
                assert not ImageChops.difference(corners[0], corners[2]).getbbox(), 'dock radius did not restore'
                cfg.write_text(original)
                ipc.reload_config()
                ipc.wait_for_frame()
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
                settings_idle = pill('settings', 'settings-idle')
                click(button('settings'))
                wait_for(lambda: ipc.get_shell_state()['control_center'], 'dock settings')
                wait_for(shortcuts_only, 'Settings shares its shortcut')
                assert ImageChops.difference(settings_idle, pill('settings', 'settings-running')).getbbox()
                # A running shortcut has the same window actions as an unpinned app.
                ipc.move_cursor(*center(button('settings')))
                ipc.pointer_button(273, True)
                ipc.pointer_button(273, False)
                for code in (108, 28):  # Down selects Close; Enter activates it.
                    ipc.key(code, True)
                    ipc.key(code, False)
                wait_for(lambda: not ipc.get_shell_state()['control_center'], 'shortcut menu closes Settings')
                ipc.wait_for_frame()
                ipc.wait_for('catalog_published', timeout_ms=10000)
                for shortcut, app_id, desktop_id, height in (
                    ('files', 'dock.files.running', 'dock-files.desktop', 48),
                    ('terminal', 'dock.terminal.running', 'dock-terminal.desktop', 96),
                    ('terminal', 'dock.fallback', None, 68),
                ):
                    text = cfg.read_text()
                    previous_height = tomllib.loads(text)['compositor']['dock_height']
                    cfg.write_text(text.replace(f'dock_height = {previous_height}', f'dock_height = {height}'))
                    ipc.reload_config()
                    wait_for(lambda: dock()[0]['global_box']['height'] == height, 'height reload')
                    if desktop_id is None:
                        cfg.write_text(cfg.read_text().replace('default_terminal = "dock-terminal.desktop"', 'default_terminal = ""'))
                        ipc.reload_config()
                        ipc.wait_for_frame()
                    idle = pill(shortcut, f'{app_id}-idle')
                    position = button(shortcut)['global_box']
                    click(button(shortcut))
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w['app_id'] == app_id), None), 'shortcut launch')
                    wid = win['id']
                    wait_for(shortcuts_only, 'launch must not add another dock icon')
                    assert button(shortcut)['global_box'] == position, 'launch changed dock geometry'
                    running = pill(shortcut, f'{app_id}-running')
                    assert ImageChops.difference(idle, running).getbbox(), 'running pill missing'
                    click(button(shortcut))
                    wait_for(lambda: next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'shortcut minimizes its app')
                    assert len(ipc.get_windows()) == 1, 'shortcut launched another instance'
                    click(button(shortcut))
                    wait_for(lambda: not next(w for w in ipc.get_windows() if w['id'] == wid)['is_minimized'], 'shortcut restores its app')
                    assert len(ipc.get_windows()) == 1
                    assert ipc.get_focused_window()['id'] == wid
                    if desktop_id:
                        ipc.action('launch_app', {'desktop_id': desktop_id})
                        second = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] != wid), None), 'second instance')
                        wait_for(shortcuts_only, 'multiple windows share one shortcut')
                        ipc.action('close_window', {'id': second['id']})
                        wait_for(lambda: len(ipc.get_windows()) == 1, 'second window closed')
                        assert ImageChops.difference(idle, pill(shortcut, f'{app_id}-one-left')).getbbox(), 'pill disappeared with a window left'
                    if shortcut == 'files':
                        before_removal = cfg.read_text()
                        ipc.move_cursor(*center(button(shortcut)))
                        ipc.pointer_button(273, True)
                        ipc.pointer_button(273, False)
                        for code in (103, 28):  # Up selects Remove from dock.
                            ipc.key(code, True)
                            ipc.key(code, False)
                        wait_for(lambda: not any(w['name'] == 'files' for w in dock()), 'running shortcut removed')
                        assert not any((w['name'] or '').startswith('window_') for w in dock()), 'removed shortcut left a duplicate'
                        assert len(ipc.get_windows()) == 1, 'removing shortcut closed the app'
                        cfg.write_text(before_removal)
                        ipc.reload_config()
                        wait_for(shortcuts_only, 'shortcut restored with its running app')
                    ipc.action('close_window', {'id': wid})
                    wait_for(lambda: not ipc.get_windows(), 'last window closed')
                    ipc.wait_for_frame()
                    restored = pill(shortcut, f'{app_id}-closed')
                    difference = ImageChops.difference(idle, restored)
                    assert max(high for low, high in difference.getextrema()) <= 1, 'pill survived the last window'
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
            print(f'PASS: dock defaults, Appearance height, persistence, hover, grouped launchers, running pills, windows, fullscreen, reload ({scale}x)')
        except Exception:
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


def context_menu():
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-menu-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        env_extra = {'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
                     'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
                     'XDG_CACHE_HOME': str(tmp / 'cache')}
        process, log = spawn_compositor(tmp, scale=scale,
            outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
            config_content='# keep this comment\n[compositor]\nxwayland = false\ndock_enabled = true\ndock_height = 96\n'
                           '[animations]\nenabled = false\n', env_extra=env_extra)
        cfg = tmp / 'rediwm-config.toml'
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*')
                    if not p.name.endswith('.lock')), None), 'display')

                def names():
                    return {w['name'] for w in ui.widgets('dock') if w['name']}

                def launch(app):
                    previous = {w['id'] for w in ipc.get_windows()}
                    client = subprocess.Popen([str(tmp / 'client'), '--app-id', app],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    clients.append(client)
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] not in previous), None), 'client')
                    ipc.wait_for_frame()
                    return client, win['id']

                def menu(name):
                    widget = wait_for(lambda: next((w for w in ui.widgets('dock') if w['name'] == name), None), name)
                    box = widget['global_box']
                    x = round(box['x'] + box['width'] / 2)
                    ipc.move_cursor(x, round(box['y'] + box['height'] / 2))
                    ipc.pointer_button(273, True)
                    ipc.pointer_button(273, False)
                    ipc.wait_for_frame()
                    height = 122 if name.startswith('window_') else 44
                    return x, ui.widgets('dock')[0]['global_box']['y'] - height - 4

                def key(code):
                    ipc.key(code, True)
                    ipc.key(code, False)

                first, wid = launch('dock.removed')
                second, other_id = launch('dock.removed')
                x, y = menu(f'window_{wid}')
                ipc.click_at(x + 20, y + 41)  # Separator is inert.
                assert len(ipc.get_windows()) == 2
                key(1)  # Escape
                menu(f'window_{wid}')
                ipc.click_at(5, 5)  # Outside dismisses without activating the dock.
                assert len(ipc.get_windows()) == 2
                menu(f'window_{wid}')
                key(103)  # Up selects Remove from dock.
                key(28)
                wait_for(lambda: not any(n.startswith('window_') for n in names()), 'app removed')
                assert {w['id'] for w in ipc.get_windows()} == {wid, other_id}
                assert len(ipc.get_shell_state()['taskbars'][0]['chips']) == 2
                assert tomllib.loads(cfg.read_text())['compositor']['dock_hidden_apps'] == ['dock.removed']
                ipc.reload_config()
                assert not any(n.startswith('window_') for n in names())

                x, y = menu('terminal')
                ipc.click_at(x + 20, y + 22)
                wait_for(lambda: 'terminal' not in names(), 'shortcut removed')
                assert tomllib.loads(cfg.read_text())['compositor']['dock_hidden_shortcuts'] == ['terminal']
                assert '# keep this comment' in cfg.read_text()

                client, close_id = launch('dock.close')
                x, y = menu(f'window_{close_id}')
                ipc.click_at(x + 20, y + 22)
                wait_for(lambda: all(w['id'] != close_id for w in ipc.get_windows()), 'Close')
                assert client.wait(timeout=5) == 0
                client, hung_id = launch('dock.hung')
                ipc.action('minimize_window', {'id': hung_id})
                client.send_signal(signal.SIGSTOP)
                menu(f'window_{hung_id}')
                key(108)
                key(108)  # Down selects Force Close, skipping the separator.
                key(28)
                wait_for(lambda: all(w['id'] != hung_id for w in ipc.get_windows()), 'Force Close')
                assert client.wait(timeout=5) == -signal.SIGKILL

                client, gone_id = launch('dock.gone')
                menu(f'window_{gone_id}')
                stop_process(client)
                wait_for(lambda: all(w['id'] != gone_id for w in ipc.get_windows()), 'menu target gone')
                ipc.wait_for_frame()
                assert process.poll() is None

                # An anonymous window can be hidden without hiding other anonymous windows.
                anonymous, anon_id = launch('')
                anonymous2, anon_id2 = launch('')
                menu(f'window_{anon_id}')
                key(103)
                key(28)
                wait_for(lambda: f'window_{anon_id}' not in names(), 'anonymous window removed')
                assert f'window_{anon_id2}' in names()
                assert len(ipc.get_windows()) == 4
                stop_process(anonymous)
                stop_process(anonymous2)
                wait_for(lambda: len(ipc.get_windows()) == 2, 'anonymous cleanup')

                # Disabling the dock dismisses even a shortcut menu with no window target.
                menu('applications')
                cfg.write_text(cfg.read_text().replace('dock_enabled = true', 'dock_enabled = false'))
                ipc.reload_config()
                wait_for(lambda: not names(), 'disabled dock')
                key(28)
                assert tomllib.loads(cfg.read_text())['compositor']['dock_hidden_shortcuts'] == ['terminal']
                cfg.write_text(cfg.read_text().replace('dock_enabled = false', 'dock_enabled = true'))
                ipc.reload_config()
                wait_for(names, 'dock restored')
                for shortcut in ('files', 'applications', 'settings'):
                    menu(shortcut)
                    key(103)
                    key(28)
                    wait_for(lambda: shortcut not in names(), 'shortcut removed')
                assert not names(), 'empty dock should be hidden'
                saved = cfg.read_text()

            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()
            process, log = spawn_compositor(tmp, scale=scale, config_content=saved, env_extra=env_extra)
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*')
                    if not p.name.endswith('.lock')), None), 'display after restart')
                assert not names(), 'removed shortcuts returned after restart'
                client, reopened = launch('dock.removed')
                assert not names(), 'removed app returned after restart'
                assert any(c['window_id'] == reopened for c in ipc.get_shell_state()['taskbars'][0]['chips'])
                cfg.write_text(cfg.read_text().replace(
                    'dock_hidden_shortcuts = ["terminal", "files", "applications", "settings"]',
                    'dock_hidden_shortcuts = []').replace('[compositor]', '[compositor]\ntaskbar_position = "top"'))
                ipc.reload_config()
                wait_for(lambda: names() == {'applications', 'files', 'terminal', 'settings'}, 'shortcuts restored')
                assert ui.widgets('dock')[0]['global_box']['height'] == 96, 'dock height lost after restart'
                # A dock menu stays above the dock with a top taskbar, too.
                x, y = menu('settings')
                ipc.click_at(x + 20, y + 22)
                wait_for(lambda: 'settings' not in names(), 'menu anchored to dock')
            print(f'PASS: dock context menu, Close, Force Close, removal, dismissal, anonymous windows, persistence ({scale}x)')
        except Exception:
            log.flush()
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


def pill_animation():
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-dock-pill-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        process, log = spawn_compositor(tmp, scale=scale,
            outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
            config_content='[compositor]\nxwayland = false\ndock_enabled = true\n'
                           '[animations]\nenabled = true\nspeed = 1.0\nreduced_motion = "off"\n',
            env_extra={'DBUS_SESSION_BUS_ADDRESS': '', 'XDG_CONFIG_HOME': str(tmp / 'config'),
                       'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_DATA_DIRS': str(tmp / 'empty'),
                       'XDG_CACHE_HOME': str(tmp / 'cache'), 'TERMINAL': 'foot'})
        clients = []
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                primary = ipc.get_outputs()[0]['name']
                prefix = f'dock.{primary}.terminal.pill_'
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*')
                    if not p.name.endswith('.lock')), None), 'display')
                ui = UIDriver(ipc)
                clock = 1000
                ipc.action('set_anim_time', {'ms': clock})
                ipc.wait_for_frame(output=primary)

                def state(part='width'):
                    return next(a for a in ipc.action('get_animations') if a['site'] == prefix + part)

                def advance(ms):
                    nonlocal clock
                    clock += ms
                    ipc.action('set_anim_time', {'ms': clock})
                    ipc.wait_for_frame(output=primary)

                def launch(app):
                    previous = {w['id'] for w in ipc.get_windows()}
                    client = subprocess.Popen([str(tmp / 'client'), '--app-id', app],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    clients.append(client)
                    win = wait_for(lambda: next((w for w in ipc.get_windows() if w['id'] not in previous), None), 'client')
                    ipc.wait_for_frame(output=primary)
                    return win['id']

                def pixels(name):
                    path = tmp / (name + '.png')
                    ipc.screenshot(str(path))
                    widgets = ui.widgets('dock')
                    b = next(w['global_box'] for w in widgets if w['name'] == 'terminal')
                    root = widgets[0]['global_box']
                    x, y = b['x'] + b['width'] / 2, b['y'] + b['height'] + 1
                    with Image.open(path) as image:
                        return image.convert('RGB').crop(tuple(round(v * scale) for v in
                            (x - 14, y, x + 14, root['y'] + root['height'] - 2)))

                idle = pixels('idle')
                wid = launch('foot')
                assert state()['target'] == 22 and state()['value'] == 0
                assert state()['curve'] == 'spring' and not state()['settled']
                advance(60)
                growing = state()
                assert 0 < growing['value'] < 22
                assert 0 < state('opacity')['value'] < 1
                assert ImageChops.difference(idle, pixels('growing')).getbbox(), 'animated pill did not paint'
                ipc.action('minimize_window', {'id': wid})
                ipc.wait_for_frame(output=primary)
                shrinking = state()
                assert shrinking['target'] == 10
                assert abs(shrinking['value'] - growing['value']) < 0.001
                assert abs(shrinking['velocity'] - growing['velocity']) < 0.001
                advance(60)
                before = state()
                ipc.action('restore_window', {'id': wid})
                ipc.wait_for_frame(output=primary)
                after = state()
                assert after['target'] == 22 and abs(after['value'] - before['value']) < 0.001
                assert abs(after['velocity'] - before['velocity']) < 0.001
                advance(1000)
                assert state()['settled'] and state()['value'] == 22

                other = launch('dock.pill.other')
                assert state()['target'] == 10 and state()['value'] == 22
                advance(60)
                before = state()
                assert 10 < before['value'] < 22
                cfg = tmp / 'rediwm-config.toml'
                cfg.write_text(cfg.read_text().replace('[compositor]', '[compositor]\ndock_hidden_shortcuts = ["files"]'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                after = state()
                assert abs(after['value'] - before['value']) < 0.001, 'dock rebuild restarted the pill'
                assert abs(after['velocity'] - before['velocity']) < 0.001
                cfg.write_text(cfg.read_text().replace('speed = 1.0', 'speed = 0.5'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                assert abs(state()['value'] - before['value']) < 0.001, 'speed reload jumped the pill'
                advance(1000)
                assert state()['value'] == 10 and state()['settled']
                cfg.write_text(cfg.read_text().replace('dock_hidden_shortcuts = ["files"]\n', ''))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                ipc.action('close_window', {'id': other})
                wait_for(lambda: len(ipc.get_windows()) == 1, 'other closed')
                ipc.wait_for_frame(output=primary)
                ipc.action('close_window', {'id': wid})
                wait_for(lambda: not ipc.get_windows(), 'terminal closed')
                ipc.wait_for_frame(output=primary)
                assert state()['target'] == 0 and state('opacity')['target'] == 0
                advance(60)
                assert 0 < state('opacity')['value'] < 1, 'pill disappeared without fading'
                advance(1000)
                assert state()['value'] == 0 and state('opacity')['value'] == 0
                difference = ImageChops.difference(idle, pixels('gone'))
                assert max(high for low, high in difference.getextrema()) <= 1, 'faded pill left pixels'
                ipc.reset_perf()
                for _ in range(3):
                    ipc.wait_for_frame(output=primary)
                assert ipc.get_perf()['anim_frames_scheduled'] == 0, 'pinned animation spins'

                # Turning animations off settles a transition immediately.
                wid = launch('foot')
                advance(60)
                cfg.write_text(cfg.read_text().replace('\nenabled = true\n', '\nenabled = false\n'))
                ipc.reload_config()
                ipc.wait_for_frame(output=primary)
                assert state()['value'] == 22 and state()['settled']
                ipc.action('minimize_window', {'id': wid})
                ipc.wait_for_frame(output=primary)
                assert state()['value'] == 10 and state('opacity')['value'] == 0.4

                # Reduced motion jumps width but retains the short opacity fade.
                cfg.write_text(cfg.read_text().replace('\nenabled = false\n', '\nenabled = true\n').replace('reduced_motion = "off"', 'reduced_motion = "on"'))
                ipc.reload_config()
                ipc.action('restore_window', {'id': wid})
                ipc.wait_for_frame(output=primary)
                assert state()['value'] == 22 and state()['settled']
                advance(1000)
                assert state('opacity')['settled'] and state('opacity')['value'] == 1
                ipc.action('set_anim_time', {'ms': None})
                ipc.move_cursor(5, 5)
                ipc.wait_for_frame(output=primary)
                ipc.reset_perf()
                before = ipc.get_perf()
                for _ in range(3):
                    ipc.wait_for_frame(output=primary)
                after = ipc.get_perf()
                assert after['anim_frames_scheduled'] == 0, 'settled pills keep requesting frames'
                assert (after['panel_allocated_bytes'] + after['panel_reused_bytes'] ==
                        before['panel_allocated_bytes'] + before['panel_reused_bytes']), 'settled pills keep repainting'
            print(f'PASS: dock pill growth, focus, reversal, fading, rebuild, speed, reduced motion and idle ({scale}x)')
        except Exception:
            log.flush()
            print((tmp / 'compositor.log').read_text()[-4000:])
            raise
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == '__main__':
    run()
    context_menu()
    pill_animation()
