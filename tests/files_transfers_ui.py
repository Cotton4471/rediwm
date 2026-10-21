#!/usr/bin/env python3
"""Files add flow and background tray, on a private headless desktop."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import libtorrent as lt
from files_torrents import Client, wait, ROOT
from ipc_client import IPCClient, spawn_compositor, stop_process

def run():
    with tempfile.TemporaryDirectory(prefix='rediwm-transfer-ui-') as directory:
        tmp = Path(directory)
        home = tmp/'Home'; home.mkdir()
        torrent = tmp/'example.torrent'
        torrent.write_bytes(lt.bencode({'info': {'name': 'example.txt', 'length': 5, 'piece length': 16384, 'pieces': hashlib.sha1(b'hello').digest()}}))
        shim = tmp/'network.so'
        subprocess.run(['cc','-shared','-fPIC',str(ROOT/'tests/torrent_network.c'),'-o',str(shim),'-ldl'],check=True)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(tmp), XDG_STATE_HOME=str(tmp/'state'),
                   XDG_DATA_HOME=str(tmp/'data'), XDG_CONFIG_HOME=str(tmp/'config'), HOME=str(home),
                   GIO_USE_VFS='local', REDIWM_FILES_DEVICES='0', REDIWM_APP_SCOPES='0', LD_PRELOAD=str(shim),
                   DBUS_SYSTEM_BUS_ADDRESS='unix:path=/nonexistent-rediwm-test-bus')
        for key in ('REDIWM_SOCKET', 'WAYLAND_DISPLAY', 'DISPLAY'):
            env.pop(key, None)
        binary_dir = Path(os.environ.get('REDIWM_TEST_BIN_DIR', ROOT/'zig-out/bin'))
        proc, log = spawn_compositor(tmp, binary=binary_dir/'rediwm', env_extra=dict({k:v for k,v in env.items() if k != "LD_PRELOAD"}, REDIWM_FORCE_DBUS='1', WLR_RENDERER_ALLOW_SOFTWARE='1',
                                                       PULSE_SERVER='unix:/nonexistent-rediwm-test-audio'))
        files = None; client = None
        try:
            # This socket pattern deliberately excludes the transfer service.
            ipc_path = wait(lambda: next(iter(tmp.glob('rediwm-*.sock')),None),'compositor socket')
            with IPCClient(ipc_path) as ipc:
                ipc.wait_for('wallpaper_presented',timeout_ms=10000)
                display = wait(lambda: next((p.name for p in tmp.glob('wayland-*') if not p.name.endswith('.lock')),None),'Wayland')
                env['WAYLAND_DISPLAY'] = display
                files = subprocess.Popen([str(binary_dir/'rediwm-files'),'--torrent',str(torrent)],env=env,stdout=log,stderr=log)
                def windows(): return [w for w in ipc.get_windows() if w['app_id']=='rediwm-files']
                win = wait(lambda: next(iter(windows()),None),'Files window')
                ipc.focus_window(win['id']); ipc.wait_for('window_geometry_settled',window_id=win['id'])
                wait(lambda: (tmp/'files-transfers.sock').exists(),'helper socket')
                client = Client(tmp)
                time.sleep(.3)
                ipc.key_down_up(28)  # Confirm the displayed destination folder.
                rows = client.until(lambda r: r if r else None,'UI adds torrent')
                assert rows[0]['pending'] and rows[0]['metadata']
                rect = ipc.get_window_debug(win['id'])['client_box']
                width,height = rect['width'],rect['height']
                bx=(width-min(720,width-24))/2; by=(height-min(560,height-24))/2
                def pane_click(x,y): ipc.click_at(round(rect['x']+x),round(rect['y']+y)); time.sleep(.15)
                def click(x,y): pane_click(bx+x,by+y)
                def title(): return next(w['title'] for w in windows() if w['id'] == win['id'])
                wait(lambda: title().startswith('Transfers —'),'Transfers uses the main pane')
                Path('/tmp/rediwm-transfers-list.png').unlink(missing_ok=True)
                ipc.screenshot(path='/tmp/rediwm-transfers-list.png',window_id=win['id'])
                pane_click(60,82) # Add torrent is in the ordinary Files toolbar.
                ipc.key_down_up(1) # Cancel returns to the list.
                assert title().startswith('Transfers —')
                pane_click(283,180) # first list row opens its file selection
                Path('/tmp/rediwm-transfers-files.png').unlink(missing_ok=True)
                ipc.screenshot(path='/tmp/rediwm-transfers-files.png',window_id=win['id'])
                click(min(720,width-24)-75,min(560,height-24)-42) # Start download
                client.until(lambda r: r and not r[0]['pending'] and not r[0]['paused'],'UI starts torrent')
                ipc.key_down_up(1) # Close details, leaving the transfer list visible.
                pane_click(290,82) # Stop seeding must preserve an active download.
                client.until(lambda r: r and not r[0]['paused'],'Stop seeding preserves downloads')
                pane_click(180,82) # Pause all in the main toolbar.
                client.until(lambda r: r and r[0]['paused'],'toolbar Pause all')
                pane_click(283,180)
                click(76,164) # Resume from transfer details.
                client.until(lambda r: r and not r[0]['paused'],'resume after toolbar pause')
                ipc.key_down_up(1)
                ipc.action('set_window_size', {'id': win['id'], 'width': 360, 'height': 540})
                ipc.wait_for('window_geometry_settled',window_id=win['id'])
                rect = ipc.get_window_debug(win['id'])['client_box']
                pane_click(170,128) # Narrow windows wrap the torrent actions below the view icons.
                client.until(lambda r: r and r[0]['paused'],'narrow toolbar Pause all')
                Path('/tmp/rediwm-transfers-narrow.png').unlink(missing_ok=True)
                ipc.screenshot(path='/tmp/rediwm-transfers-narrow.png',window_id=win['id'])
                client.send(op='resume',id=rows[0]['id'])
                client.until(lambda r: r and not r[0]['paused'],'resume after narrow toolbar pause')
                ipc.action('set_window_size', {'id': win['id'], 'width': width, 'height': height})
                ipc.wait_for('window_geometry_settled',window_id=win['id'])
                rect = ipc.get_window_debug(win['id'])['client_box']
                pane_click(27,28) # Back returns to the previous folder.
                wait(lambda: not title().startswith('Transfers —'),'Back leaves Transfers')
                # Grid cards have the same inline controls on their detail line.
                pane_click(425,227)
                client.until(lambda r: r and r[0]['paused'],'grid card Pause')
                pane_click(425,227)
                client.until(lambda r: r and not r[0]['paused'],'grid card Resume')
                # Download controls are also available in the destination folder.
                pane_click(width-233,82) # ordinary Files list view
                time.sleep(.3)
                name_right = 228 + (width-208-40-14)*.5 - 4
                toggle_x, ring_x = name_right-14, name_right-46
                pane_click(toggle_x,180)
                client.until(lambda r: r and r[0]['paused'],'folder row Pause')
                pane_click(toggle_x,180)
                client.until(lambda r: r and not r[0]['paused'],'folder row Resume')
                ipc.action('move_cursor', {'x': round(rect['x']+ring_x), 'y': round(rect['y']+180)})
                time.sleep(.2)
                Path('/tmp/rediwm-transfers-folder.png').unlink(missing_ok=True)
                ipc.screenshot(path='/tmp/rediwm-transfers-folder.png',window_id=win['id'])
                # Keyboard activation on a staging entry opens transfer details.
                pane_click(280,180)
                ipc.key_down_up(57)
                client.until(lambda r: r and r[0]['paused'],'keyboard row Pause')
                ipc.key_down_up(57)
                client.until(lambda r: r and not r[0]['paused'],'keyboard row Resume')
                ipc.key_down_up(28)
                ipc.key_down_up(1)
                # The actual .torrent file has the same controls, independent of its destination.
                ipc.key(29,True); ipc.key_down_up(38); ipc.key(29,False)
                ipc.type_text(str(tmp)); ipc.key_down_up(28)
                wait(lambda: title().startswith(tmp.name+' —'),'source folder')
                ipc.key(29,True); ipc.key_down_up(33); ipc.key(29,False)
                ipc.type_text('example.torrent'); time.sleep(.3)
                pane_click(toggle_x,180)
                client.until(lambda r: r and r[0]['paused'],'source .torrent row Pause')
                pane_click(toggle_x,180)
                client.until(lambda r: r and not r[0]['paused'],'source .torrent row Resume')
                ipc.key(29,True); ipc.key_down_up(38); ipc.key(29,False)
                ipc.type_text(str(home)); ipc.key_down_up(28)
                wait(lambda: title().startswith('Home —'),'return to download folder')
                # The sidebar remains usable while viewing Transfers.
                # Ten places and a 40px block gap precede Transfers at this height.
                pane_click(80,532)
                wait(lambda: title().startswith('Transfers —'),'sidebar reopens Transfers')
                Path('/tmp/rediwm-transfers-list.png').unlink(missing_ok=True)
                ipc.screenshot(path='/tmp/rediwm-transfers-list.png',window_id=win['id'])
                def icons(): return ipc.get_shell_state()['taskbars'][0]['app_tray']
                wait(lambda: len(icons())==1,'active transfer tray icon')
                ipc.close_window(win['id']); files.wait(timeout=8)
                client.until(lambda r: r and not r[0]['paused'],'transfer survives Files closing')
                icon=icons()[0]['box']
                ipc.click_at(icon['x']+icon['width']//2,icon['y']+icon['height']//2)
                reopened = wait(lambda: next(iter(windows()),None),'tray reopens Files')
                ipc.wait_for('window_geometry_settled',window_id=reopened['id'])
                icon=icons()[0]['box']
                ipc.click_at(icon['x']+icon['width']//2,icon['y']+icon['height']//2,0x111)
                menu=wait(lambda: ipc.get_shell_state()['taskbars'][0]['tray_menu'],'tray menu')
                ipc.click_at(menu['x']+80,menu['y']+8+30+15) # Pause all
                client.until(lambda r: r and r[0]['paused'],'tray Pause all')
                wait(lambda: not icons(),'paused transfers hide tray icon')
                client.send(op='remove',id=rows[0]['id']); client.until(lambda r:not r,'cleanup transfer')
                ipc.close_window(reopened['id']); wait(lambda:not windows(),'reopened Files closes')
                print('PASS: main-pane Transfers, folder and source row pause/resume, hover details, narrow layout, file selection, start and background tray')
        except Exception:
            print((tmp/"compositor.log").read_text(), file=sys.stderr)
            raise
        finally:
            if client:
                try:
                    client.send(op='pause_all')
                    client.until(lambda r:all(t['paused'] for t in r),'cleanup pauses work',5)
                except (OSError,AssertionError): pass
                client.close()
            if files: stop_process(files)
            stop_process(proc); log.close()
            # Helper exits after its final subscriber leaves, with no active work.
            wait(lambda:not (tmp/'files-transfers.sock').exists(),'helper exits',12)

if __name__=='__main__':
    if '--private-bus' not in sys.argv:
        raise SystemExit(subprocess.call(['dbus-run-session','--',sys.executable,__file__,'--private-bus']))
    run()
