#!/usr/bin/env python3
"""Taskbar sections, live settings, input, legacy config and persistence."""
import os
from pathlib import Path
import subprocess
import tempfile
import tomllib

from desktop_zoom import build_client, wait_for
from ipc_client import IPCClient, spawn_compositor, stop_process
from ui_driver import UIDriver


def run():
    scale = float(os.environ.get('REDIWM_TEST_SCALE', '1'))
    with tempfile.TemporaryDirectory(prefix='rediwm-taskbar-sections-') as directory:
        tmp = Path(directory)
        build_client(tmp)
        env_extra = {'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': 'unix:path=/nonexistent',
                     'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
                     'XDG_CACHE_HOME': str(tmp / 'cache')}
        original = '# preserve me\n[compositor]\nxwayland = false\n[animations]\nenabled = false\n'
        process, log = spawn_compositor(tmp, scale=scale, outputs=os.environ.get('REDIWM_TEST_OUTPUTS', '1'),
                                        config_content=original, env_extra=env_extra)
        clients = []
        cfg = tmp / 'rediwm-config.toml'
        try:
            with IPCClient(tmp) as ipc:
                ipc.wait_for('wallpaper_presented', timeout_ms=10000)
                ui = UIDriver(ipc)
                display = wait_for(lambda: next((p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock')), None), 'display')
                for index in range(2):
                    clients.append(subprocess.Popen([str(tmp / 'client'), '--app-id', f'taskbar.section.{index}'],
                        env=dict(os.environ, XDG_RUNTIME_DIR=str(tmp), WAYLAND_DISPLAY=display),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                wait_for(lambda: len(ipc.get_windows()) == 2, 'windows')
                ipc.wait_for_frame()
                def bar():
                    return ui.widgets('taskbar')
                def box(name):
                    return next(w['global_box'] for w in bar() if w['name'] == name)
                def center(b):
                    return round(b['x'] + b['width'] / 2), round(b['y'] + b['height'] / 2)
                def chips():
                    return [w['global_box'] for w in bar() if w['role'] == 'chip']
                def check_bounds():
                    root = bar()[0]['global_box']
                    items = [w['global_box'] for w in bar()[1:] if w['visible']]
                    items.sort(key=lambda b: b['x'])
                    for b in items:
                        assert root['x'] <= b['x'] and b['x'] + b['width'] <= root['x'] + root['width'], (root, b)
                        assert ipc.hit_test(*center(b))['target_type'] == 'taskbar', b
                    for a, b in zip(items, items[1:]):
                        assert a['x'] + a['width'] <= b['x'] + 1, (a, b)
                root = bar()[0]['global_box']
                row = chips()
                assert abs((row[0]['x'] + row[-1]['x'] + row[-1]['width']) / 2 - (root['x'] + root['width'] / 2)) <= 1, row
                assert box('start')['x'] < row[0]['x'] < box('clock')['x']
                check_bounds()
                ipc.action('open_appearance')
                ipc.wait_for_panel_settled('control_center')
                for name, expected in (('start', 0), ('windows', 1), ('tray', 2), ('clock', 2)):
                    assert ui.scroll_into_view(f'taskbar_{name}_section')['selected_index'] == expected
                # Move fixed controls and both primary groups to every section.
                for name in ('clock', 'network', 'volume', 'start', 'windows', 'tray'):
                    for zone in (0, 1, 2):
                        widget = ui.scroll_into_view(f'taskbar_{name}_section')
                        area = widget['global_box']
                        ipc.click_at(round(area['x'] + area['width'] * (zone + .5) / 3), round(area['y'] + area['height'] / 2))
                        wait_for(lambda: ui.find(f'taskbar_{name}_section')['selected_index'] == zone, 'section selection')
                        if widget['selected_index'] != zone:
                            wait_for(lambda: any(entry.lstrip('-') == f'{("left", "center", "right")[zone]}:{name}'
                                for entry in tomllib.loads(cfg.read_text())['compositor']['taskbar_items']), 'section saved')
                        ipc.wait_for_frame()
                        ipc.wait_for_panel_settled('control_center')
                        check_bounds()
                # Drag order and keyboard order stay inside the chosen section.
                before = tomllib.loads(cfg.read_text())['compositor']['taskbar_items']
                handle = ui.scroll_into_view('taskbar_network_order')
                volume = ui.scroll_into_view('taskbar_volume_order')
                handle = ui.find('taskbar_network_order')
                fx, fy = center(handle['global_box'])
                tx, ty = center(volume['global_box'])
                assert handle['visible'] and not handle['clipped'], handle
                ipc.drag(fx, fy, tx, ty + (3 if fy < ty else -3))
                wait_for(lambda: tomllib.loads(cfg.read_text())['compositor']['taskbar_items'] != before, 'drag reorder')
                ipc.wait_for_panel_settled('control_center')
                dragged = tomllib.loads(cfg.read_text())['compositor']['taskbar_items']
                assert (dragged.index('right:network') > dragged.index('right:volume')) != (before.index('right:network') > before.index('right:volume')), dragged
                handle = ui.scroll_into_view('taskbar_network_order')
                ipc.click_at(*center(handle['global_box']))
                ipc.key(108, True)
                ipc.key(108, False)
                wait_for(lambda: tomllib.loads(cfg.read_text())['compositor']['taskbar_items'] != dragged, 'keyboard reorder')
                ipc.wait_for_panel_settled('control_center')
                assert '# preserve me' in cfg.read_text()
                # Hide and restore the window group without changing windows.
                toggle = ui.scroll_into_view('taskbar_windows_visible')
                ipc.click_at(*center(toggle['global_box']))
                wait_for(lambda: not chips(), 'hidden window list')
                assert len([w for w in ipc.get_windows() if w['app_id'].startswith('taskbar.section.')]) == 2
                toggle = ui.scroll_into_view('taskbar_windows_visible')
                ipc.click_at(*center(toggle['global_box']))
                wait_for(lambda: chips(), 'window list restored')
                ipc.action('close_panel', {'panel': 'control_center'})
                ipc.wait_for_frame()
                # Start's hit target and menu follow its moved position.
                ipc.click_at(*center(box('start')))
                wait_for(lambda: ipc.get_shell_state()['start_menu'], 'moved Start button opens menu')
                menu = ipc.get_shell_state()['start_menu']['box']
                assert root['x'] <= menu['x'] and menu['x'] + menu['width'] <= root['x'] + root['width'], menu
                ipc.key(1, True)
                ipc.key(1, False)
                wait_for(lambda: not ipc.get_shell_state()['start_menu'], 'Start menu dismissed')
                saved = cfg.read_text()
                # The original status-only config still preserves order/hiding.
                cfg.write_text(original.replace('[compositor]', '[compositor]\ntaskbar_items = ["clock", "-network", "volume", "battery"]'))
                ipc.reload_config()
                wait_for(lambda: not any(w['name'] == 'tray/1' for w in bar()), 'legacy hidden network')
                assert box('clock')['x'] < box('tray/0')['x']
                row = chips()
                assert abs((row[0]['x'] + row[-1]['x'] + row[-1]['width']) / 2 - (root['x'] + root['width'] / 2)) <= 1
                cfg.write_text(saved)
            for client in clients:
                stop_process(client)
            clients.clear()
            stop_process(process)
            log.close()
            process, log = spawn_compositor(tmp, scale=scale, config_content=cfg.read_text(), env_extra=env_extra)
            with IPCClient(tmp) as ipc:
                ipc.action('open_appearance')
                ipc.wait_for_panel_settled('control_center')
                ui = UIDriver(ipc)
                assert ui.scroll_into_view('taskbar_start_section')['selected_index'] == 2
                assert ui.scroll_into_view('taskbar_windows_section')['selected_index'] == 2
                assert ui.scroll_into_view('taskbar_clock_section')['selected_index'] == 2
            print(f'PASS: taskbar sections, center default, section moves, bounds/input, visibility, Start menu, legacy config and restart ({scale}x)')
        finally:
            for client in clients:
                stop_process(client)
            stop_process(process)
            log.close()


if __name__ == '__main__':
    run()
