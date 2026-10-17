#!/usr/bin/env python3
"""Printers Settings against private scripted CUPS and helper fixtures.

Needs the regular headless compositor dependencies and wl-paste. All CUPS
responses are synthetic; no host queue, service, USB node or printer is used.
Confirmed test documents terminate in the fixture's memory, without a backend.
"""
import os
import json
from pathlib import Path
import pwd
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time
import select
import sys

from ipc_client import IPCClient, spawn_compositor, stop_process
from power_profiles import wait_for
from ui_driver import UIDriver
from xwayland_support import wayland_display_name


def cups_ready(ui):
    widgets = ui.widgets('control_center')
    return (any(w.get('name') == 'printers_refresh' and not w['is_disabled'] for w in widgets)
            and not any(w.get('name') == 'printers_status' for w in widgets))


def select_printer(ipc, ui, index):
    wait_for(lambda: not ui.find('printers_printer', panel='control_center')['is_disabled'],
             'printer selector enabled', timeout=15)
    widget = ui.scroll_into_view('printers_printer', panel='control_center')
    ui.click(widget, panel='control_center')
    ipc.key_press('Home')
    for _ in range(index):
        ipc.key_press('Down')
    ipc.key_press('Return')
    wait_for(lambda: cups_ready(ui), 'selected printer ready', timeout=15)
    ui.wait_settled('control_center')
    assert ui.find('printers_printer', panel='control_center')['selected_index'] == index


def attribute(tag, name, value):
    name = name.encode()
    if tag in (0x21, 0x23):
        value = struct.pack('!i', value)
    elif tag == 0x22:
        value = bytes([bool(value)])
    elif tag == 0x32:
        value = struct.pack('!iiB', *value)
    else:
        value = value.encode()
    return bytes([tag]) + struct.pack('!H', len(name)) + name + struct.pack('!H', len(value)) + value


def request_attributes(body):
    """Decode scalar request fields needed to assert operation ownership."""
    fields, offset, name = {}, 8, ''
    while offset < len(body):
        tag = body[offset]
        offset += 1
        if tag == 3:
            fields['_document'] = body[offset:]
            break
        if tag < 0x10:
            continue
        length = struct.unpack_from('!H', body, offset)[0]
        offset += 2
        if length:
            name = body[offset:offset + length].decode()
        offset += length
        length = struct.unpack_from('!H', body, offset)[0]
        offset += 2
        value = body[offset:offset + length]
        offset += length
        fields[name] = struct.unpack('!i', value)[0] if tag in (0x21, 0x23) else bool(value[0]) if tag == 0x22 else value.decode()
    return fields


def printer_workers(process):
    """Read only this test compositor's named printer worker and counters."""
    workers = {}
    for task in Path(f'/proc/{process.pid}/task').iterdir():
        try:
            if task.joinpath('comm').read_text().strip() != 'rediwm-printers':
                continue
            fields = dict(line.split(':', 1) for line in task.joinpath('status').read_text().splitlines())
            workers[task.name] = (int(fields['voluntary_ctxt_switches']), int(fields['nonvoluntary_ctxt_switches']))
        except FileNotFoundError:
            # Other compositor threads may exit during /proc enumeration.
            continue
    return workers


class Scheduler(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, path):
        self.lock = threading.Lock()
        self.events = []
        self.fault = ''
        self.empty = False
        self.denied = False
        self.stopped = False
        self.cancelled = False
        self.job_state = 3
        self.release = threading.Event()
        self.username = pwd.getpwuid(os.getuid()).pw_name
        super().__init__(str(path), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def configure(self, **values):
        with self.lock:
            for key, value in values.items():
                setattr(self, key, value)

    def calls(self):
        with self.lock:
            return list(self.events)

    def reply(self, operation, fields):
        with self.lock:
            self.events.append((operation, fields))
            fault = self.fault
            empty, stopped, denied = self.empty, self.stopped, self.denied
            cancelled = self.cancelled
            job_state = self.job_state
            if operation == 8 and not denied:
                self.cancelled = True
        if fault == 'stall':
            self.release.wait(12)
        if fault == 'malformed':
            return 200, b'not an IPP response'
        if fault == 'http':
            return 503, b'fixture unavailable'
        status = 0x0403 if operation == 8 and denied else 0x0406 if operation == 0x4002 and empty else 0
        response = struct.pack('!BBHI', 2, 0, status, fields.pop('_request_id'))
        response += b'\x01' + attribute(0x47, 'attributes-charset', 'utf-8')
        response += attribute(0x48, 'attributes-natural-language', 'en')
        if status:
            response += attribute(0x41, 'status-message', 'Fixture denied cancellation' if denied else 'No destinations')
        elif operation == 0x4002 and not empty:
            for index, (name, model) in enumerate((('Label_Test', 'Fixture thermal printer'), ('Office_Test', 'Fixture office printer'))):
                response += b'\x04'
                response += attribute(0x42, 'printer-name', name)
                response += attribute(0x41, 'printer-info', name.replace('_', ' '))
                response += attribute(0x41, 'printer-make-and-model', model)
                response += attribute(0x45, 'printer-uri-supported', 'ipp://localhost/printers/' + name)
                response += attribute(0x45, 'device-uri', 'socket://operator:fixture-password@private-printer.invalid:9100/')
                response += attribute(0x23, 'printer-state', 5 if stopped and index == 0 else 3)
                response += attribute(0x22, 'printer-is-accepting-jobs', not (stopped and index == 0))
                response += attribute(0x44, 'printer-state-reasons', 'media-empty-error' if stopped and index == 0 else 'none')
                response += attribute(0x41, 'printer-state-message', 'Out of paper' if stopped and index == 0 else 'Ready')
                response += attribute(0x44, 'media-default', 'na_index-4x6_4x6in')
                if index:
                    # Largest signed IPP resolution in dpcm used to overflow
                    # the conversion to DPI when this queue was selected.
                    response += attribute(0x32, 'printer-resolution-default', (2147483647, 3, 4))
                response += attribute(0x49, 'document-format-supported', 'application/pdf')
                response += attribute(0x42, 'marker-names', 'Black')
                response += attribute(0x21, 'marker-levels', 42 if index else -1)
        elif operation == 0x000a and not empty:
            response += b'\x02'
            response += attribute(0x21, 'job-id', 17)
            if cancelled or job_state is not None:
                response += attribute(0x23, 'job-state', 7 if cancelled else job_state)
            response += attribute(0x42, 'job-originating-user-name', self.username)
            response += attribute(0x42, 'job-name', 'PRIVATE-DOCUMENT-NAME')
            response += attribute(0x45, 'job-printer-uri', 'ipp://localhost/printers/Label_Test')
            response += attribute(0x44, 'job-state-reasons', 'job-canceled-by-user' if cancelled else 'job-incoming')
            response += attribute(0x21, 'job-media-sheets-completed', 0)
            for job_id in range(16, 8, -1):
                response += b'\x02'
                response += attribute(0x21, 'job-id', job_id)
                response += attribute(0x23, 'job-state', 8 if job_id == 15 else 9)
                response += attribute(0x42, 'job-originating-user-name', self.username)
                response += attribute(0x42, 'job-name', 'OLDER-PRIVATE-DOCUMENT')
                response += attribute(0x45, 'job-printer-uri', 'ipp://localhost/printers/Label_Test')
                response += attribute(0x44, 'job-state-reasons', 'job-completed-successfully')
                response += attribute(0x21, 'job-media-sheets-completed', 0)
                if job_id == 16:
                    response += attribute(0x41, 'job-printer-state-message', 'No pages were found.')
            # Even a scheduler that ignores my-jobs must not make another
            # user's pending job cancellable in the page.
            response += b'\x02'
            response += attribute(0x21, 'job-id', 18)
            response += attribute(0x23, 'job-state', 3)
            response += attribute(0x42, 'job-originating-user-name', 'fixture-other-user')
            response += attribute(0x42, 'job-name', 'OTHER-PRIVATE-DOCUMENT')
            response += attribute(0x45, 'job-printer-uri', 'ipp://localhost/printers/Label_Test')
        return 200, response + b'\x03'

    def close(self):
        self.release.set()
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=2)


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            line = self.rfile.readline(4096)
            if not line:
                return
            assert line.startswith(b'POST '), line
            headers = {}
            while True:
                line = self.rfile.readline(4096)
                if line in (b'\r\n', b'\n', b''):
                    break
                key, value = line.decode().split(':', 1)
                headers[key.lower()] = value.strip()
            length = int(headers['content-length'])
            assert 8 <= length <= 1024 * 1024, length
            body = self.rfile.read(length)
            fields = request_attributes(body)
            fields['_request_id'] = struct.unpack_from('!I', body, 4)[0]
            operation = struct.unpack_from('!H', body, 2)[0]
            status, response = self.server.reply(operation, fields)
            self.wfile.write(f'HTTP/1.1 {status} Fixture\r\nContent-Type: application/ipp\r\nContent-Length: {len(response)}\r\nConnection: close\r\n\r\n'.encode() + response)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass


class TcpEndpoint(socketserver.ThreadingTCPServer):
    """A private loopback scheduler or the one selected printer's IPP endpoint."""
    daemon_threads = True
    block_on_close = False

    def __init__(self, scheduler=None):
        self.scheduler = scheduler
        self.events = []
        super().__init__(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    @property
    def uri(self):
        return f'ipp://127.0.0.1:{self.server_address[1]}/ipp/print'

    def reply(self, operation, fields):
        self.events.append((operation, dict(fields)))
        if self.scheduler:
            return self.scheduler.reply(operation, fields)
        assert operation == 11, 'only the explicitly selected printer may be probed'
        response = struct.pack('!BBHI', 2, 0, 0, fields['_request_id']) + b'\x01'
        response += attribute(0x47, 'attributes-charset', 'utf-8') + attribute(0x48, 'attributes-natural-language', 'en')
        response += b'\x04' + attribute(0x23, 'printer-state', 3)
        response += attribute(0x49, 'document-format-supported', 'application/pdf')
        response += attribute(0x44, 'ipp-features-supported', 'ipp-everywhere')
        return 200, response + b'\x03'

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=2)


def run(scale):
    with tempfile.TemporaryDirectory(prefix='rediwm-printers-') as directory:
        tmp = Path(directory)
        scheduler = Scheduler(tmp / 'cups.sock')
        process, log = spawn_compositor(tmp, scale=scale, config_content='[compositor]\nxwayland = false\n', env_extra={
            'CUPS_SERVER': str(tmp / 'cups.sock'), 'CUPS_USER': scheduler.username, 'CUPS_ENCRYPTION': 'Never',
            'HOME': str(tmp), 'XDG_CONFIG_HOME': str(tmp / 'config'),
            'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
            'DBUS_SESSION_BUS_ADDRESS': '', 'PIPEWIRE_RUNTIME_DIR': str(tmp),
            'DBUS_SYSTEM_BUS_ADDRESS': '',
            'PULSE_SERVER': 'unix:/nonexistent-rediwm-printers-test-pulse',
        })
        try:
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)

                def named(name):
                    return ui.find(name, panel='control_center')

                def labels():
                    return [widget.get('label') or '' for widget in ui.widgets('control_center')]

                def click(name):
                    wait_for(lambda: not named(name)['is_disabled'], name + ' enabled')
                    widget = ui.scroll_into_view(name, panel='control_center')
                    ui.click(widget, panel='control_center')
                    if widget['role'] != 'select':
                        ui.wait_settled('control_center')

                def ready():
                    wait_for(lambda: cups_ready(ui), 'CUPS ready', timeout=15)

                def refresh():
                    before = len(scheduler.calls())
                    click('printers_refresh')
                    wait_for(lambda: len(scheduler.calls()) > before, 'refresh reached private CUPS')
                    ready()

                def error_finished():
                    def finished():
                        text = named('printers_status')['label']
                        return text and text not in ('Connected to CUPS.', 'Loading printers…')
                    return wait_for(finished, 'visible CUPS error', timeout=15)

                ipc.open_control_center()
                ui.wait_settled('control_center')
                assert not scheduler.calls(), 'CUPS must remain untouched until Printers is shown'
                assert not printer_workers(process), 'printer worker must not exist before its page is shown'
                click('printers')
                ready()
                assert any(operation == 0x4002 for operation, _ in scheduler.calls())
                assert any(operation == 0x000a and fields.get('my-jobs') is True and fields.get('which-jobs') == 'all'
                           for operation, fields in scheduler.calls()), scheduler.calls()
                select_printer(ipc, ui, 0)
                assert any('Label' in text for text in labels()), labels()
                names = {w.get('name') for w in ui.widgets()}
                assert 'printers_cancel_17' in names, 'active jobs remain visible'
                assert not names & {'printers_job_16', 'printers_copy_report', 'printers_rename', 'printers_raw_dpi'}, 'secondary sections start collapsed'
                assert not any('No pages were found.' in text for text in labels()), 'historical details start hidden'
                click('printers_history')
                names = {w.get('name') for w in ui.widgets()}
                assert {f'printers_job_{i}' for i in range(12, 18)} <= names
                assert 'printers_job_11' not in names, 'history initially shows five jobs'
                assert not any('No pages were found.' in text for text in labels()), 'history rows start compact'
                click('printers_job_16')
                assert 'No pages were found.' in labels(), 'individual history details remain accessible'
                refresh()
                assert 'No pages were found.' in labels(), 'refresh preserves the open job'
                click('printers_job_16')
                assert 'No pages were found.' not in labels()
                click('printers_history_more')
                names = {w.get('name') for w in ui.widgets()}
                assert 'printers_job_9' in names and 'printers_history_more' not in names
                click('printers_history')
                assert not any(w.get('name') == 'printers_job_16' for w in ui.widgets())
                assert not any('PRIVATE-DOCUMENT' in text for text in labels()), labels()
                assert not any(widget.get('name') == 'printers_cancel_18' for widget in ui.widgets()), 'another user\'s job must not be cancellable'
                if preview := os.environ.get('REDIWM_PRINTERS_PREVIEW'):
                    ui.scroll_into_view('printers_printer', panel='control_center')
                    ui.wait_settled('control_center')
                    captured = tmp / 'printers-preview.png'
                    ipc.screenshot(str(captured))
                    Path(preview).write_bytes(captured.read_bytes())
                select_printer(ipc, ui, 1)
                assert 'Resolution: Unavailable' in labels(), 'hostile dpcm resolution must be unavailable, without overflowing'
                select_printer(ipc, ui, 0)

                for job_state in (4, 6, None):
                    scheduler.configure(job_state=job_state)
                    refresh()
                    names = {w.get('name') for w in ui.widgets()}
                    assert 'printers_job_17' in names, 'held, stopped and unknown jobs must stay in the current queue'
                    assert ('printers_cancel_17' in names) == (job_state is not None)
                scheduler.configure(job_state=3)
                refresh()

                if scale == '1':
                    window = next(w for w in ipc.get_windows() if w.get('app_id') == 'rediwm-settings')
                    for width in (620, 820, 1120):
                        ipc.action('set_window_size', {'id': window['id'], 'width': width, 'height': 580})
                        ipc.wait_for('window_geometry_settled', window_id=window['id'])
                        ui.wait_settled('control_center')
                        test_box = named('printers_test_page')['box']
                        default_box = named('printers_default')['box']
                        selector = named('printers_printer')
                        assert selector['role'] == 'select'
                        assert selector['box']['y'] < test_box['y'], 'printer dropdown stays above details'
                        assert not any((w.get('name') or '').startswith('printers_queue_') for w in ui.widgets()), 'no printer sidebar remains'
                        assert abs(selector['box']['x'] + 14 - test_box['x']) < 1, 'details use the full width below the dropdown'
                        if width < 760:
                            assert default_box['y'] >= test_box['y'] + test_box['height'], 'narrow actions stack'
                        else:
                            assert abs(default_box['y'] - test_box['y']) < 1, 'wide actions share a row'
                        click('printers_history')
                        click('printers_history')

                # Check the worker itself, as well as scheduler request count:
                # an idle timer can wake without issuing a CUPS request.
                count = len(scheduler.calls())
                before_idle = printer_workers(process)
                assert len(before_idle) == 1, before_idle
                time.sleep(1)
                assert len(scheduler.calls()) == count, scheduler.calls()
                after_idle = printer_workers(process)
                assert before_idle.keys() == after_idle.keys(), 'idle printer worker was replaced or exited'
                for task, before in before_idle.items():
                    deltas = tuple(after - previous for after, previous in zip(after_idle[task], before))
                    assert all(delta >= 0 for delta in deltas) and sum(deltas) <= 2, f'idle printer worker context switches: {deltas}'
                    print('Printer worker idle context-switch deltas: voluntary=%d involuntary=%d' % deltas)

                click('printers_diagnostics')
                click('printers_copy_report')
                copied = subprocess.check_output(['wl-paste', '--no-newline'], env={
                    **os.environ, 'XDG_RUNTIME_DIR': str(tmp), 'WAYLAND_DISPLAY': wayland_display_name(tmp),
                }, timeout=5).decode()
                assert copied.startswith('RediWM printer diagnostics\n'), copied
                assert 'Queue state: idle; accepting: yes' in copied, copied
                assert 'Label_Test' not in copied, copied
                assert 'fixture-password' not in copied and 'private-printer.invalid' not in copied, copied
                assert 'PRIVATE-DOCUMENT' not in copied, copied

                click('printers_cancel_17')
                wait_for(lambda: any(operation == 8 and fields.get('job-id') == 17 for operation, fields in scheduler.calls()), 'own job cancellation')
                ready()
                assert 'No active jobs' in labels()
                assert not any(w.get('name') == 'printers_cancel_17' for w in ui.widgets()), 'cancelled jobs leave the active queue'
                scheduler.configure(cancelled=False, denied=True)
                refresh()
                click('printers_cancel_17')
                wait_for(lambda: 'CUPS denied permission. The operation requires authorization.' in labels(), 'cancellation permission error')

                scheduler.configure(denied=False, stopped=True)
                refresh()
                assert any('Out of paper' in text for text in labels()), labels()
                scheduler.configure(empty=True)
                refresh()
                assert 'No printers configured.' in labels(), labels()
                scheduler.configure(empty=False, fault='malformed')
                click('printers_refresh')
                error_finished()
                scheduler.configure(fault='http')
                click('printers_refresh')
                error_finished()
                scheduler.configure(fault='')
                refresh()

                scheduler.configure(fault='stall')
                before = len(scheduler.calls())
                click('printers_refresh')
                wait_for(lambda: len(scheduler.calls()) > before, 'stalled request reached CUPS')
                started = time.monotonic()
                ipc.get_shell_state()
                assert time.monotonic() - started < 2, 'a stalled CUPS must not block compositor IPC'
                error_finished()
                scheduler.configure(fault='')
                scheduler.release.set()
                refresh()

                # Global search replaces the body while Printers stays selected.
                # Its worker and CUPS activity must stop until results are cleared.
                click('settings_search')
                ipc.type_text('volume')
                ui.wait_settled('control_center')
                assert not printer_workers(process), 'global search must join the printer worker'
                count = len(scheduler.calls())
                time.sleep(.3)
                assert len(scheduler.calls()) == count, 'global search must not retain CUPS activity'
                ipc.key_press('Escape')
                ui.wait_settled('control_center')
                ready()
                wait_for(lambda: len(printer_workers(process)) == 1, 'printer worker after clearing search')

                # Leaving the page must cancel an outstanding socket deadline.
                scheduler.release.clear()
                scheduler.configure(fault='stall')
                before = len(scheduler.calls())
                click('printers_refresh')
                wait_for(lambda: len(scheduler.calls()) > before, 'in-flight request before hide')
                started = time.monotonic()
                click('shortcuts')
                assert time.monotonic() - started < 2, 'hiding Printers must cancel blocked I/O promptly'
                assert not printer_workers(process), 'hiding Printers must join its worker'
                scheduler.configure(fault='')
                scheduler.release.set()
                count = len(scheduler.calls())
                time.sleep(1)
                assert len(scheduler.calls()) == count, 'hidden Printers must release its activity'
                click('printers')
                ready()
                wait_for(lambda: len(scheduler.calls()) > count, 'refresh when shown again')
                window = next(window for window in ipc.get_windows() if window.get('app_id') == 'rediwm-settings')
                ipc.close_window(window['id'])
                count = len(scheduler.calls())
                time.sleep(1)
                assert len(scheduler.calls()) == count, 'closed Settings must stop CUPS work'
                assert not printer_workers(process), 'closing Settings must join the printer worker'
            stop_process(process)
            log.flush()
            contents = (tmp / 'compositor.log').read_text()
            assert ' leaked:' not in contents and 'memory address' not in contents, contents[-3000:]
            print('Printers Settings passed at scale', scale)
        except Exception:
            log.flush()
            Path('/tmp/rediwm-printers-compositor.log').write_text((tmp / 'compositor.log').read_text())
            raise
        finally:
            if process.poll() is None:
                stop_process(process)
            log.close()
            scheduler.close()


def endpoint_errors(scale):
    # An unsupported TCP endpoint is our own listener, so even a regression
    # cannot contact a real scheduler. It must remain unconnected.
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen(1)
        listener.setblocking(False)
        for endpoint in ('missing', f'ipps://127.0.0.1:{listener.getsockname()[1]}'):
            with tempfile.TemporaryDirectory(prefix='rediwm-printers-endpoint-') as directory:
                tmp = Path(directory)
                configured = str(tmp / 'missing-cups.sock') if endpoint == 'missing' else endpoint
                process, log = spawn_compositor(tmp, scale=scale, config_content='[compositor]\nxwayland = false\n', env_extra={
                    'CUPS_SERVER': configured, 'CUPS_ENCRYPTION': 'Never', 'HOME': str(tmp),
                    'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'),
                    'XDG_CACHE_HOME': str(tmp / 'cache'), 'DBUS_SESSION_BUS_ADDRESS': '',
                    'DBUS_SYSTEM_BUS_ADDRESS': '',
                    'PIPEWIRE_RUNTIME_DIR': str(tmp), 'PULSE_SERVER': 'unix:/nonexistent-rediwm-printers-test-pulse',
                })
                try:
                    with IPCClient(tmp, timeout=15) as ipc:
                        ui = UIDriver(ipc)
                        ipc.open_control_center()
                        ui.wait_settled('control_center')
                        ui.click(ui.find('printers', panel='control_center'), panel='control_center')
                        def expected_error():
                            text = ui.find('printers_status', panel='control_center').get('label', '') or ''
                            return ('unavailable' in text.lower() or 'not running' in text.lower()) if endpoint == 'missing' else ('encrypted' in text.lower() or 'unsupported' in text.lower() or 'not supported' in text.lower())
                        wait_for(expected_error, 'missing or encrypted server error', timeout=15)
                    try:
                        connection, _ = listener.accept()
                    except BlockingIOError:
                        pass
                    else:
                        connection.close()
                        raise AssertionError('unsupported CUPS_SERVER must fail before a TCP connection')
                except Exception:
                    log.flush()
                    Path('/tmp/rediwm-printers-endpoint-compositor.log').write_text((tmp / 'compositor.log').read_text())
                    raise
                finally:
                    stop_process(process)
                    log.close()
    print('Missing and unsupported CUPS endpoints passed at scale', scale)


# Independent private fixture, with no service activation file and no access to
# the system bus. Its method shapes mirror cups-pk-helper's actual ABI.
FAKE_HELPER = r'''
import json, os, sys
from pathlib import Path
from gi.repository import Gio, GLib
name = 'org.opensuse.CupsPkHelper.Mechanism'
root = Path(os.environ['PRINTER_FIXTURE_ROOT'])
state_path = root / 'queues.json'
methods = {
 'DevicesGet': ('iiasas', 'sa{ss}'),
 'PrinterAdd': ('sssss', 's'), 'PrinterDelete': ('s', 's'),
 'PrinterSetEnabled': ('sb', 's'), 'PrinterSetAcceptJobs': ('sbs', 's'),
 'PrinterSetDefault': ('s', 's'), 'PrinterSetInfo': ('ss', 's'), 'PrinterRename': ('ss', 's'),
 'PrinterSetDevice': ('ss', 's'),
 'PrinterAddOptionDefault': ('ssas', 's'), 'PrinterDeleteOptionDefault': ('ss', 's'),
 'PrinterAddOption': ('ssas', 's'),
}
def signatures(signature):
 if signature == 'iiasas': return ['i', 'i', 'as', 'as']
 if signature == 'sa{ss}': return ['s', 'a{ss}']
 if signature == 'ssas': return ['s', 's', 'as']
 return list(signature)
xml = '<node><interface name="' + name + '">'
for method, (inputs, outputs) in methods.items():
 xml += '<method name="' + method + '">'
 for direction, signature in [('in', inputs), ('out', outputs)]:
  for typ in signatures(signature): xml += '<arg type="' + typ + '" direction="' + direction + '"/>'
 xml += '</method>'
xml += '</interface></node>'
conn = Gio.bus_get_sync(Gio.BusType.SESSION)
def record(method, args):
 with (root / 'helper.jsonl').open('a') as output: output.write(json.dumps([method, args]) + '\n')
def called(connection, sender, path, interface, method, parameters, invocation):
 args = parameters.unpack()
 record(method, args)
 if (root / 'deny').exists():
  invocation.return_dbus_error(name + '.NotPrivileged', 'Fixture refused authorization')
  return
 if method == 'DevicesGet':
  assert args[0] > 0 and args[1] <= 128 and args[2] == [] and set(args[3]) == {'file', 'smb', 'smbs', 'pdf', 'pipe', 'exec', 'command', 'beh', 'hpfax', 'mailto'}
  invocation.return_value(GLib.Variant('(sa{ss})', ('', {
   'device-uri:0': 'usb://Fixture/Label?serial=setup-only', 'device-info:0': 'Fixture detected label',
   'device-make-and-model:0': 'Fixture Label', 'device-id:0': 'MFG:Fixture;MDL:Label;CMD:TSPL;',
   'device-class:0': 'direct',
   'device-uri:1': os.environ['PRINTER_FIXTURE_NETWORK_URI'], 'device-info:1': 'Fixture network printer',
   'device-make-and-model:1': 'Fixture Office', 'device-id:1': 'MFG:Fixture;MDL:Office;CMD:POSTSCRIPT;',
   'device-class:1': 'network',
   # These are unsupported backends, never selectable in the add UI.
   'device-uri:2': 'file:/tmp/must-not-print', 'device-info:2': 'Forbidden file backend',
   'device-uri:3': 'smb://user:password@private.invalid/queue', 'device-info:3': 'Forbidden SMB backend',
   'device-uri:4': 'tspl:/dev/usb/lp0', 'device-info:4': 'Fixture vendor label',
   'device-make-and-model:4': 'Fixture Label', 'device-id:4': 'MFG:Fixture;MDL:Label;CMD:TSPL;',
   'device-class:4': 'direct',
  })))
  return
 state = json.loads(state_path.read_text())
 queues = state['queues']
 key = args[0]
 if method == 'PrinterAdd':
  assert key not in queues, 'the UI must never upsert an existing queue'
  assert args[1].startswith(('ipp://', 'ipps://', 'socket://', 'lpd://', 'usb://', 'dnssd://', 'tspl:/'))
  queues[key] = {'uri': args[1], 'ppd': args[2], 'info': args[3], 'enabled': False, 'accepting': False, 'options': {}}
 elif key not in queues:
  invocation.return_value(GLib.Variant('(s)', ('Unknown queue',)))
  return
 elif method == 'PrinterDelete': del queues[key]
 elif method == 'PrinterSetEnabled': queues[key]['enabled'] = args[1]
 elif method == 'PrinterSetAcceptJobs': queues[key]['accepting'] = args[1]
 elif method == 'PrinterSetDefault': state['default'] = key
 elif method == 'PrinterSetInfo': queues[key]['info'] = args[1]
 elif method == 'PrinterSetDevice': queues[key]['uri'] = args[1]
 elif method == 'PrinterRename':
  if any(existing.lower() == args[1].lower() for existing in queues):
   invocation.return_value(GLib.Variant('(s)', ('Queue already exists',)))
   return
  queues[args[1]] = queues.pop(key)
  if state.get('default') == key: state['default'] = args[1]
 elif method == 'PrinterAddOptionDefault': queues[key].setdefault('overrides', {})[args[1]] = args[2][0]
 elif method == 'PrinterAddOption':
  option, value = args[1], args[2][0]
  queues[key]['options'][option] = value
  alias = {'Resolution': 'printer-resolution', 'SetResolution': 'printer-resolution', 'JCLResolution': 'printer-resolution', 'CNRes_PGP': 'printer-resolution', 'PageSize': 'media', 'PageRegion': 'media', 'Duplex': 'sides', 'ColorModel': 'print-color-mode', 'cupsPrintQuality': 'print-quality'}.get(option)
  if alias:
   if alias == 'media': value = {'A4': 'iso_a4_210x297mm', '4x6': 'na_index-4x6_4x6in'}[value]
   elif alias == 'sides': value = {'None': 'one-sided', 'DuplexNoTumble': 'two-sided-long-edge'}[value]
   elif alias == 'print-color-mode': value = {'Gray': 'monochrome', 'RGB': 'color'}[value]
   elif alias == 'print-quality': value = {'Draft': '3', 'Normal': '4', 'High': '5'}[value]
   queues[key]['options'][alias] = value
 elif method == 'PrinterDeleteOptionDefault': queues[key].setdefault('overrides', {}).pop(args[1], None)
 pending = state_path.with_suffix('.pending')
 pending.write_text(json.dumps(state))
 pending.replace(state_path)
 invocation.return_value(GLib.Variant('(s)', ('',)))
conn.register_object('/', Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0], called, None, None)
reply = conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', (name, 0)), None, Gio.DBusCallFlags.NONE, -1, None)
assert reply.unpack()[0] == 1
service_xml = """<node><interface name='org.freedesktop.systemd1.Manager'>
<method name='StartUnit'><arg type='s' direction='in'/><arg type='s' direction='in'/><arg type='o' direction='out'/></method>
</interface></node>"""
def service_called(connection, sender, path, interface, method, parameters, invocation):
 args = parameters.unpack()
 assert method == 'StartUnit' and args == ('cups.service', 'replace'), (method, args)
 record(method, args)
 invocation.return_value(GLib.Variant('(o)', ('/org/freedesktop/systemd1/job/1',)))
conn.register_object('/org/freedesktop/systemd1', Gio.DBusNodeInfo.new_for_xml(service_xml).interfaces[0], service_called, None, None)
reply = conn.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', ('org.freedesktop.systemd1', 0)), None, Gio.DBusCallFlags.NONE, -1, None)
assert reply.unpack()[0] == 1
def stdin_ready(*_):
 command = sys.stdin.readline().strip()
 if command == 'notify':
  conn.emit_signal(None, '/org/cups/cupsd/Notifier', 'org.cups.cupsd.Notifier', 'PrinterStateChanged', GLib.Variant('(s)', ('Forged desktop-user hint',)))
  conn.flush_sync(None)
  print('notified', flush=True)
 return True
GLib.io_add_watch(sys.stdin, GLib.IO_IN, stdin_ready)
print('ready', flush=True)
GLib.MainLoop().run()
'''


# The helper's actual ABI targets the system's default local scheduler. Redirect
# only that socket in this noninstalled fixture so production enforces exactly
# the same canonical-server gate in the test, without touching a host cupsd.
CUPS_CONNECT_HOOK = r'''
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
int connect(int fd, const struct sockaddr *address, socklen_t length) {
 int (*real_connect)(int, const struct sockaddr *, socklen_t) = dlsym(RTLD_NEXT, "connect");
 if (!real_connect) { errno = EIO; return -1; }
 if (address && address->sa_family == AF_UNIX && length > offsetof(struct sockaddr_un, sun_path)) {
  const struct sockaddr_un *local = (const struct sockaddr_un *)address;
  size_t available = length - offsetof(struct sockaddr_un, sun_path);
  if (available > sizeof(local->sun_path)) available = sizeof(local->sun_path);
  size_t size = strnlen(local->sun_path, available);
  if ((size == 19 && memcmp(local->sun_path, "/run/cups/cups.sock", 19) == 0) ||
      (size == 23 && memcmp(local->sun_path, "/var/run/cups/cups.sock", 23) == 0)) {
   const char *redirect = getenv("PRINTER_FIXTURE_CUPS_SOCKET");
   if (!redirect || !*redirect || strlen(redirect) >= sizeof(local->sun_path)) { errno = EINVAL; return -1; }
   struct sockaddr_un target = { .sun_family = AF_UNIX };
   strcpy(target.sun_path, redirect);
   return real_connect(fd, (const struct sockaddr *)&target, offsetof(struct sockaddr_un, sun_path) + strlen(redirect) + 1);
  }
 }
 return real_connect(fd, address, length);
}
'''


class SetupScheduler(Scheduler):
    """Queues shared with the private helper; documents never leave memory."""
    def __init__(self, path, state):
        self.state_path = state
        self.printed = []
        self.next_job = 40
        self.active_job = False
        self.active_job_state = 3
        self.jobs_denied = False
        super().__init__(path)

    def state(self):
        return json.loads(self.state_path.read_text())

    @staticmethod
    def effective(queue):
        options = queue.get('options', {})
        return {
            'media': options.get('media', 'iso_a4_210x297mm' if options.get('PageSize') == 'A4' else 'na_index-4x6_4x6in'),
            'resolution': options.get('printer-resolution', options.get('Resolution', '300dpi')),
            'sides': options.get('sides', 'two-sided-long-edge' if options.get('Duplex') == 'DuplexNoTumble' else 'one-sided'),
            'color': options.get('print-color-mode', 'color' if options.get('ColorModel') == 'RGB' else 'monochrome'),
            'quality': options.get('print-quality', {'Draft': '3', 'Normal': '4', 'High': '5'}.get(options.get('cupsPrintQuality'), '4')),
            'darkness': options.get('Darkness', '8'),
        }

    def reply(self, operation, fields):
        with self.lock:
            self.events.append((operation, dict(fields)))
            if self.fault == 'http':
                return 503, b'Fixture CUPS stopped'
            if operation == 2:
                self.next_job += 1
                self.printed.append(dict(fields, id=self.next_job))
            job = self.next_job
        status = 0x0403 if operation == 0x000a and self.jobs_denied else 0
        response = struct.pack('!BBHI', 2, 0, status, fields['_request_id'])
        response += b'\x01' + attribute(0x47, 'attributes-charset', 'utf-8') + attribute(0x48, 'attributes-natural-language', 'en')
        if status:
            return 200, response + attribute(0x41, 'status-message', 'Fixture job query denied') + b'\x03'
        state = self.state()
        if operation in (0x4002, 0x000b):
            for key, queue in state['queues'].items():
                if operation == 0x000b and not fields.get('printer-uri', '').endswith('/' + key):
                    continue
                options = self.effective(queue)
                response += b'\x04' + attribute(0x42, 'printer-name', key)
                response += attribute(0x41, 'printer-info', queue.get('info', key))
                response += attribute(0x41, 'printer-make-and-model', 'Fixture thermal printer' if key == 'Label_Test' else 'Fixture office printer')
                response += attribute(0x45, 'printer-uri-supported', 'ipp://localhost/printers/' + key)
                response += attribute(0x45, 'device-uri', queue['uri'])
                response += attribute(0x41, 'printer-device-id', 'MFG:Fixture;MDL:Label;CMD:TSPL;')
                response += attribute(0x23, 'printer-state', 3 if queue.get('enabled', True) else 5)
                response += attribute(0x22, 'printer-is-accepting-jobs', queue.get('accepting', True))
                response += attribute(0x44, 'printer-state-reasons', 'none')
                response += attribute(0x41, 'printer-state-message', 'Ready')
                response += attribute(0x23, 'printer-type', 0x20000 if state.get('default') == key else 0)
                response += attribute(0x44, 'media-default', options['media'])
                response += attribute(0x44, 'media-supported', 'na_index-4x6_4x6in') + attribute(0x44, '', 'iso_a4_210x297mm')
                dpi = int(options['resolution'].removesuffix('dpi').split('x')[0])
                response += attribute(0x32, 'printer-resolution-default', (dpi, dpi, 3))
                response += attribute(0x32, 'printer-resolution-supported', (203, 203, 3)) + attribute(0x32, '', (300, 300, 3))
                response += attribute(0x44, 'print-color-mode-default', options['color'])
                response += attribute(0x44, 'print-color-mode-supported', 'monochrome') + attribute(0x44, '', 'color')
                response += attribute(0x44, 'sides-default', options['sides'])
                response += attribute(0x44, 'sides-supported', 'one-sided') + attribute(0x44, '', 'two-sided-long-edge')
                response += attribute(0x23, 'print-quality-default', int(options['quality']))
                response += attribute(0x23, 'print-quality-supported', 3) + attribute(0x23, '', 4) + attribute(0x23, '', 5)
                response += attribute(0x49, 'document-format-supported', 'application/pdf')
        elif operation == 0x400c:
            response += b'\x04' + attribute(0x42, 'ppd-name', 'fixture-label.ppd')
            response += attribute(0x41, 'ppd-make-and-model', 'Fixture Label')
            response += attribute(0x41, 'ppd-device-id', 'MFG:Fixture;MDL:Label;CMD:TSPL;')
            response += b'\x04' + attribute(0x42, 'ppd-name', 'fixture-office.ppd')
            response += attribute(0x41, 'ppd-make-and-model', 'Fixture Office')
            response += attribute(0x41, 'ppd-device-id', 'MFG:Fixture;MDL:Office;CMD:POSTSCRIPT;')
        elif operation == 2:
            response += b'\x02' + attribute(0x21, 'job-id', job) + attribute(0x23, 'job-state', 9)
        elif operation == 0x000a and self.active_job:
            response += b'\x02' + attribute(0x21, 'job-id', 19) + attribute(0x23, 'job-state', self.active_job_state)
            response += attribute(0x42, 'job-originating-user-name', self.username)
            response += attribute(0x45, 'job-printer-uri', 'ipp://localhost/printers/Label_Test')
        elif operation == 0x0016:
            response += b'\x06' + attribute(0x21, 'notify-subscription-id', 23)
        elif operation == 0x0018:
            response += b'\x06' + attribute(0x21, 'notify-subscription-id', 23)
            response += attribute(0x21, 'notify-lease-duration', 0)
        response += b'\x03'
        if operation == 0x400f:
            queue_name = fields.get('printer-uri', '').rsplit('/', 1)[-1]
            options = self.effective(state['queues'].get(queue_name, {}))
            response += ('''*PPD-Adobe: "4.3"
*OpenGroup: General/General options
*OpenUI *PageSize/Paper size: PickOne
*DefaultPageSize: {page_size}
*PageSize 4x6/4 x 6 inch: ""
*PageSize A4/A4: ""
*CloseUI: *PageSize
*PaperDimension 4x6: "288 432"
*ImageableArea 4x6: "0 0 288 432"
*PaperDimension A4: "595.276 841.89"
*ImageableArea A4: "12 12 583.276 829.89"
*OpenUI *Resolution/Resolution: PickOne
*DefaultResolution: {resolution}
*Resolution 203dpi/203 dpi: ""
*Resolution 300dpi/300 dpi: ""
*CloseUI: *Resolution
*OpenUI *Duplex/Two-sided printing: PickOne
*DefaultDuplex: {duplex}
*Duplex None/One-sided: ""
*Duplex DuplexNoTumble/Two-sided, long edge: ""
*CloseUI: *Duplex
*OpenUI *ColorModel/Colour: PickOne
*DefaultColorModel: {color}
*ColorModel Gray/Black and white: ""
*ColorModel RGB/Colour: ""
*CloseUI: *ColorModel
*OpenUI *cupsPrintQuality/Quality: PickOne
*DefaultcupsPrintQuality: {quality}
*cupsPrintQuality Draft/Draft: ""
*cupsPrintQuality Normal/Normal: ""
*cupsPrintQuality High/High: ""
*CloseUI: *cupsPrintQuality
*CloseGroup: General
*OpenGroup: Label/Label options
*OpenUI *Darkness/Darkness: PickOne
*DefaultDarkness: {darkness}
*Darkness 8/8: ""
*Darkness 12/12: ""
*CloseUI: *Darkness
*CloseGroup: Label
'''.format(
                page_size='A4' if options['media'] == 'iso_a4_210x297mm' else '4x6',
                resolution=options['resolution'],
                duplex='DuplexNoTumble' if options['sides'] == 'two-sided-long-edge' else 'None',
                color='RGB' if options['color'] == 'color' else 'Gray',
                quality={'3': 'Draft', '4': 'Normal', '5': 'High'}[str(options['quality'])],
                darkness=options['darkness'],
            )).encode()
        return 200, response


def setup_and_tools(scale, queue_rename=True, preview=False):
    with tempfile.TemporaryDirectory(prefix='rediwm-printer-setup-') as directory:
        tmp = Path(directory)
        network = TcpEndpoint()
        state_path = tmp / 'queues.json'
        state_path.write_text(json.dumps({'queues': {
            'Label_Test': {'uri': 'usb://Fixture/Label?serial=existing', 'enabled': False, 'accepting': False, 'info': 'Fixture Label', 'options': {}},
            'Office_Test': {'uri': network.uri, 'enabled': True, 'accepting': True, 'info': 'Fixture Office', 'options': {'printer-resolution': '203dpi'}},
        }, 'default': 'Office_Test'}))
        scheduler = SetupScheduler(tmp / 'cups.sock', state_path)
        hook_source = tmp / 'cups_connect.c'
        hook_source.write_text(CUPS_CONNECT_HOOK)
        hook = tmp / 'cups_connect.so'
        subprocess.run(['cc', '-shared', '-fPIC', '-o', str(hook), str(hook_source), '-ldl'], check=True)
        bus = subprocess.Popen(['dbus-daemon', '--session', '--nofork', '--print-address=1'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        helper = None
        process = log = None
        try:
            assert select.select([bus.stdout], [], [], 10)[0], 'private printer bus startup'
            address = bus.stdout.readline().strip()
            assert address.startswith('unix:'), address
            fixture = tmp / 'helper.py'
            fixture.write_text(FAKE_HELPER)
            helper = subprocess.Popen([sys.executable, str(fixture)], env={**os.environ, 'DBUS_SESSION_BUS_ADDRESS': address, 'PRINTER_FIXTURE_ROOT': str(tmp), 'PRINTER_FIXTURE_NETWORK_URI': network.uri}, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            assert select.select([helper.stdout], [], [], 10)[0], 'private cups-pk-helper startup'
            assert helper.stdout.readline().strip() == 'ready', helper.stderr.read() if helper.poll() is not None else 'helper startup failed'
            process, log = spawn_compositor(tmp, scale=scale, config_content='[compositor]\nxwayland = false\n', env_extra={
                'CUPS_SERVER': '/run/cups/cups.sock', 'CUPS_USER': scheduler.username, 'CUPS_ENCRYPTION': 'Never',
                'LD_PRELOAD': str(hook), 'PRINTER_FIXTURE_CUPS_SOCKET': str(tmp / 'cups.sock'),
                'HOME': str(tmp), 'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
                'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': address,
                'PIPEWIRE_RUNTIME_DIR': str(tmp), 'PULSE_SERVER': 'unix:/nonexistent-rediwm-printers-test-pulse',
            })
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                def labels(): return [widget.get('label') or '' for widget in ui.widgets()]
                def named(name): return ui.find(name, panel='control_center')
                def click(name):
                    def enabled():
                        try: return not named(name)['is_disabled']
                        except LookupError: return False
                    try:
                        wait_for(enabled, name + ' enabled', timeout=15)
                    except AssertionError:
                        Path('/tmp/rediwm-printer-setup-widgets.json').write_text(json.dumps(ui.widgets(), indent=2))
                        Path('/tmp/rediwm-printer-setup-failure.png').unlink(missing_ok=True)
                        ipc.screenshot('/tmp/rediwm-printer-setup-failure.png')
                        raise AssertionError(name + ' unavailable; visible labels: ' + repr(labels()))
                    widget = ui.scroll_into_view(name, panel='control_center')
                    ui.click(widget, panel='control_center')
                    if widget['role'] != 'select':
                        ui.wait_settled('control_center')
                def fill(name, value):
                    click(name)
                    ipc.key(29, True)
                    ipc.key_press('a')
                    ipc.key(29, False)
                    ipc.type_text(value)
                def calls():
                    path = tmp / 'helper.jsonl'
                    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
                def called(member, predicate=lambda args: True):
                    return any(method == member and predicate(args) for method, args in calls())
                def ready(): wait_for(lambda: cups_ready(ui), 'CUPS ready', timeout=15)
                def quiet_inventory():
                    previous = len(scheduler.calls())
                    since = time.monotonic()
                    def quiet():
                        nonlocal previous, since
                        count = len(scheduler.calls())
                        if count != previous:
                            previous, since = count, time.monotonic()
                        return time.monotonic() - since >= .5
                    wait_for(quiet, 'automatic inventory refresh settles', timeout=10)
                    return previous
                ipc.open_control_center()
                ui.wait_settled('control_center')
                assert not calls() and not scheduler.calls(), 'opening Settings must not administer or contact CUPS'
                click('printers')
                ready()
                select_printer(ipc, ui, 0)
                click('printers_resume')
                wait_for(lambda: called('PrinterSetEnabled', lambda args: args == ['Label_Test', True]), 'resume queue')
                assert not any(w.get('name') == 'printers_accepting' for w in ui.widgets()), 'management starts collapsed'
                click('printers_manage')
                click('printers_accepting')
                wait_for(lambda: called('PrinterSetAcceptJobs', lambda args: args == ['Label_Test', True, '']), 'allow jobs')
                ready()
                wait_for(lambda: named('printers_accepting')['label'] == 'Stop accepting jobs', 'accepted queue appears in refreshed state')
                if preview:
                    click('printers_manage')
                    ui.scroll_into_view('printers_printer', panel='control_center')
                    ui.wait_settled('control_center')
                    Path('/tmp/rediwm-printers-setup-top.png').unlink(missing_ok=True)
                    ipc.screenshot('/tmp/rediwm-printers-setup-top.png')
                    click('printers_manage')
                wait_for(lambda: any(operation == 0x0016 for operation, _ in scheduler.calls()), 'page-owned CUPS subscription')
                count = quiet_inventory()
                helper.stdin.write('notify\n')
                helper.stdin.flush()
                assert select.select([helper.stdout], [], [], 5)[0], 'private forged notifier delivery'
                assert helper.stdout.readline().strip() == 'notified'
                time.sleep(.4)
                assert len(scheduler.calls()) == count, f'a desktop user cannot impersonate the privileged CUPS notifier; extra operations: {[hex(operation) for operation, _ in scheduler.calls()[count:]]}'

                # Repair a queue's connection through the helper, first with a
                # typed network URI and then an exact CUPS-discovered USB URI.
                click('printers_connection')
                fill('printers_address', network.uri)
                click('printers_connection_apply')
                wait_for(lambda: called('PrinterSetDevice', lambda args: args == ['Label_Test', network.uri]), 'typed connection update')
                wait_for(lambda: scheduler.state()['queues']['Label_Test']['uri'] == network.uri, 'connection update refresh')
                click('printers_connection')
                click('printers_discover')
                wait_for(lambda: 'Printer discovery complete.' in labels(), 'connection device discovery')
                click('printers_device_0')
                click('printers_connection_apply')
                wait_for(lambda: called('PrinterSetDevice', lambda args: args == ['Label_Test', 'usb://Fixture/Label?serial=setup-only']), 'exact discovered connection update')
                wait_for(lambda: scheduler.state()['queues']['Label_Test']['uri'] == 'usb://Fixture/Label?serial=setup-only', 'discovered connection commit')

                # All physical-output actions require a separate confirmation.
                assert not scheduler.printed, 'showing and resuming a queue must never print'
                click('printers_test_page')
                assert not scheduler.printed, 'opening print confirmation must not submit a job'
                click('printers_test_confirm')
                wait_for(lambda: len(scheduler.printed) == 1, 'confirmed driver test')
                assert scheduler.printed[0]['document-format'] == 'application/pdf', scheduler.printed
                assert scheduler.printed[0]['_document'].startswith(b'%PDF-'), scheduler.printed
                assert scheduler.printed[0]['printer-uri'].endswith('/Label_Test'), scheduler.printed
                click('printers_test_blank')
                click('printers_label_tools')
                click('printers_test_raw')
                assert len(scheduler.printed) == 1, 'raw test must require its own confirmation'
                click('printers_test_confirm')
                wait_for(lambda: len(scheduler.printed) == 2, 'confirmed raw language sample')
                assert scheduler.printed[1]['document-format'] == 'application/vnd.cups-raw', scheduler.printed
                assert scheduler.printed[1]['_document'].startswith(b'SIZE ') and scheduler.printed[1]['_document'].endswith(b'PRINT 1,1\r\n'), scheduler.printed
                click('printers_test_printed')
                wait_for(lambda: any('raw sample printed but the driver test did not' in label for label in labels()), 'driver versus backend result explanation')

                click('printers_label')
                click('printers_check_scale')
                assert len(scheduler.printed) == 2, 'ruler must require its own confirmation'
                click('printers_test_confirm')
                wait_for(lambda: len(scheduler.printed) == 3, 'confirmed ruler test')
                assert scheduler.printed[2]['document-format'] == 'application/pdf' and scheduler.printed[2]['_document'].startswith(b'%PDF-'), scheduler.printed
                assert scheduler.printed[2]['print-scaling'] == 'none', scheduler.printed
                click('printers_test_printed')
                ready()
                select_printer(ipc, ui, 1)
                ready()
                if not named('printers_label')['checked']:
                    click('printers_label')
                fill('printers_measured_width', '75.074')
                fill('printers_measured_height', '112.611')
                click('printers_calibrate')
                wait_for(lambda: any('No supported resolution' in label for label in labels()), 'the other queue must use its own 203 dpi instead of the first ruler 300 dpi')
                assert not any(widget.get('name') == 'printers_apply_resolution' for widget in ui.widgets()), 'another queue must not inherit the 300 dpi ruler receipt'
                select_printer(ipc, ui, 0)
                ready()
                fill('printers_measured_width', '75.074')
                fill('printers_measured_height', '112.611')
                click('printers_calibrate')
                click('printers_apply_resolution')
                wait_for(lambda: called('PrinterAddOption', lambda args: args[0] == 'Label_Test' and args[1] in ('printer-resolution', 'Resolution') and args[2] in (['203dpi'], ['203x203dpi'])), 'apply only the supported measured resolution')
                resolution_call = next(call for call in calls() if call[0] == 'PrinterAddOption' and call[1][0] == 'Label_Test' and call[1][1] in ('printer-resolution', 'Resolution'))
                wait_for(lambda: called('PrinterDeleteOptionDefault', lambda args: args == ['Label_Test', 'printer-resolution']), 'clear obsolete resolution override before PPD update')
                assert next(i for i, call in enumerate(calls()) if call == ['PrinterDeleteOptionDefault', ['Label_Test', 'printer-resolution']]) < calls().index(resolution_call)
                ready()
                click('printers_calibrate')
                wait_for(lambda: any('Suggested supported resolution:' in label and '203' in label for label in labels()), 'repeat calibration must use the original ruler DPI after its queue default changes')
                before_native = len(calls())
                click('printers_option_Resolution')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait_for(lambda: called('PrinterAddOption', lambda args: args == ['Label_Test', 'Resolution', ['300dpi']]), 'native PPD resolution setting')
                assert calls()[before_native:] == [
                    ['PrinterDeleteOptionDefault', ['Label_Test', 'Resolution']],
                    ['PrinterDeleteOptionDefault', ['Label_Test', 'printer-resolution']],
                    ['PrinterAddOption', ['Label_Test', 'Resolution', ['300dpi']]],
                ], 'clear native and canonical overrides before applying the native PPD choice'

                click('printers_option_Duplex')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait_for(lambda: called('PrinterAddOption', lambda args: args == ['Label_Test', 'Duplex', ['DuplexNoTumble']]), 'native duplex setting without a duplicate IPP control')
                wait_for(lambda: called('PrinterDeleteOptionDefault', lambda args: args == ['Label_Test', 'sides']), 'clear obsolete sides override before PPD update')
                assert next(i for i, call in enumerate(calls()) if call == ['PrinterDeleteOptionDefault', ['Label_Test', 'sides']]) < next(i for i, (method, args) in enumerate(calls()) if method == 'PrinterAddOption' and args[:2] == ['Label_Test', 'Duplex'])
                assert not any(w.get('name') in ('printers_option_sides', 'printers_option_printer-resolution', 'printers_option_Darkness') for w in ui.widgets()), 'everyday preferences appear once; driver extras start collapsed'
                click('printers_more_options')
                click('printers_option_Darkness')
                ipc.key_press('Down')
                ipc.key_press('Return')
                wait_for(lambda: called('PrinterAddOption', lambda args: args == ['Label_Test', 'Darkness', ['12']]), 'PPD driver-group queue setting')
                wait_for(lambda: called('PrinterDeleteOptionDefault', lambda args: args == ['Label_Test', 'Darkness']), 'clear obsolete driver-option override')
                assert next(i for i, call in enumerate(calls()) if call == ['PrinterDeleteOptionDefault', ['Label_Test', 'Darkness']]) < next(i for i, (method, args) in enumerate(calls()) if method == 'PrinterAddOption' and args[:2] == ['Label_Test', 'Darkness'])
                if preview:
                    ready()
                    ui.scroll_into_view('printers_option_Resolution', panel='control_center')
                    ui.wait_settled('control_center')
                    Path('/tmp/rediwm-printers-setup-options.png').unlink(missing_ok=True)
                    ipc.screenshot('/tmp/rediwm-printers-setup-options.png')

                click('printers_default')
                wait_for(lambda: (tmp / '.cups/lpoptions').exists() and 'Default Label_Test' in (tmp / '.cups/lpoptions').read_text(), 'private per-user default')
                assert not called('PrinterSetDefault'), 'per-user default must not become a privileged system default'
                click('printers_system_default')
                wait_for(lambda: called('PrinterSetDefault', lambda args: args == ['Label_Test']), 'explicit system default')
                fill('printers_rename', 'Fixture renamed label')
                click('printers_rename_save')
                wait_for(lambda: called('PrinterSetInfo', lambda args: args == ['Label_Test', 'Fixture renamed label']), 'safe display name change')
                assert not called('PrinterDelete'), 'display rename must preserve the queue'

                # Starting the service is a separate, fixed systemd operation;
                # reading the page or asking the helper must not start it.
                assert not called('StartUnit'), calls()
                scheduler.configure(fault='http')
                click('printers_refresh')
                click('printers_start')
                wait_for(lambda: called('StartUnit', lambda args: args == ['cups.service', 'replace']), 'explicit fixed CUPS start')
                scheduler.configure(fault='')
                click('printers_refresh')
                ready()

                # Installed driver choices come from CUPS metadata, never a
                # guessed ppd-match or package name. Discovery filters schemes.
                click('printers_add')
                click('printers_discover')
                wait_for(lambda: called('DevicesGet'), 'privileged discovery')
                wait_for(lambda: 'Printer discovery complete.' in labels(), 'discovery finished')
                assert not any('Forbidden' in label for label in labels()), labels()
                matched_device = next(widget for widget in ui.widgets() if widget.get('label') == 'Fixture vendor label')
                click(matched_device['name'])
                wait_for(lambda: named('printers_driver')['selected_index'] == 3, 'unique IEEE-1284 installed driver match')
                fill('printers_address', network.uri)
                fill('printers_name', 'Fixture_New')
                click('printers_probe')
                wait_for(lambda: named('printers_driver')['selected_index'] == 1, 'driverless capability choice replaces stale USB evidence')
                click('printers_create')
                wait_for(lambda: called('PrinterAdd', lambda args: args[0] == 'Fixture_New'), 'create printer')
                wait_for(lambda: called('PrinterSetAcceptJobs', lambda args: args == ['Fixture_New', True, '']), 'new queue enabled and accepting')
                wait_for(lambda: scheduler.state()['queues'].get('Fixture_New', {}).get('accepting') is True, 'new queue acceptance commit')
                assert len(scheduler.printed) == 3, 'adding a queue must never automatically print'
                queue = scheduler.state()['queues']['Fixture_New']
                assert queue['enabled'] and queue['accepting'] and queue['uri'] == network.uri and queue['ppd'] == 'everywhere', queue

                # An explicitly typed existing name must never become an upsert,
                # including after returning to the add flow a second time.
                adds = sum(method == 'PrinterAdd' for method, _ in calls())
                click('printers_add')
                fill('printers_address', network.uri)
                fill('printers_name', 'Fixture_New')
                click('printers_probe')
                ready()
                if not named('printers_create')['is_disabled']:
                    click('printers_create')
                assert sum(method == 'PrinterAdd' for method, _ in calls()) == adds, 'existing queues must never be silently replaced'
                assert len(scheduler.state()['queues']) == 3, scheduler.state()
                click('printers_add_cancel')

                # A vendor backend is allowed only as this exact CUPS discovery
                # result. No node is opened: the private helper stores the URI.
                click('printers_add')
                device = next(widget for widget in ui.widgets() if widget.get('label') == 'Fixture vendor label')
                click(device['name'])
                fill('printers_name', 'Vendor_Test')
                click('printers_create')
                wait_for(lambda: called('PrinterAdd', lambda args: args[:3] == ['Vendor_Test', 'tspl:/dev/usb/lp0', 'fixture-label.ppd']), 'exact CUPS-discovered vendor backend')
                wait_for(lambda: called('PrinterSetAcceptJobs', lambda args: args == ['Vendor_Test', True, '']), 'vendor queue setup completes')
                wait_for(lambda: scheduler.state()['queues'].get('Vendor_Test', {}).get('accepting') is True, 'vendor queue acceptance commit')
                assert len(scheduler.printed) == 3, 'vendor queue setup must not submit a test or open a device node'

                # A refusal remains visible and cannot change another queue.
                (tmp / 'deny').touch()
                click('printers_disable')
                wait_for(lambda: any('not authorized' in label.lower() or 'cancelled' in label.lower() for label in labels()), 'administration authorization refusal')
                (tmp / 'deny').unlink()
                assert scheduler.state()['queues']['Label_Test']['enabled'], scheduler.state()

                remove_name = 'Label_Test'
                if queue_rename:
                    # Native helper rename copies and removes a queue; root
                    # preflight must refuse collisions and active own jobs.
                    fill('printers_queue_name', 'Office_Test')
                    click('printers_queue_rename')
                    click('printers_queue_rename_confirm')
                    wait_for(lambda: any('already exists' in label.lower() for label in labels()), 'queue rename collision refusal')
                    assert not called('PrinterRename'), 'an existing destination must be refused before the helper'
                    scheduler.configure(jobs_denied=True)
                    click('printers_refresh')
                    ready()
                    fill('printers_queue_name', 'Renamed_Label')
                    click('printers_queue_rename')
                    click('printers_queue_rename_confirm')
                    ready()
                    wait_for(lambda: any('verify' in label.lower() and 'jobs' in label.lower() for label in labels()), 'queue rename refuses an unavailable job query')
                    assert not called('PrinterRename'), 'unknown jobs must not be treated as an empty queue'
                    scheduler.configure(jobs_denied=False)
                    for state in (3, 4):
                        scheduler.configure(active_job=True, active_job_state=state)
                        click('printers_refresh')
                        ready()
                        fill('printers_queue_name', 'Renamed_Label')
                        click('printers_queue_rename')
                        click('printers_queue_rename_confirm')
                        ready()
                        wait_for(lambda: any('job' in label.lower() and ('finish' in label.lower() or 'active' in label.lower()) for label in labels()), 'queue rename pending/held-job refusal')
                        assert not called('PrinterRename'), 'finish known pending or held jobs before renaming a queue'
                    scheduler.configure(active_job=False)
                    click('printers_refresh')
                    ready()
                    fill('printers_queue_name', 'Renamed_Label')
                    click('printers_queue_rename')
                    assert not called('PrinterRename'), 'queue rename must require a distinct named confirmation'
                    click('printers_queue_rename_confirm')
                    wait_for(lambda: called('PrinterRename', lambda args: args == ['Label_Test', 'Renamed_Label']), 'confirmed native queue rename')
                    wait_for(lambda: 'Renamed_Label' in scheduler.state()['queues'] and 'Label_Test' not in scheduler.state()['queues'], 'renamed queue identity')
                    wait_for(lambda: 'Default Renamed_Label' in (tmp / '.cups/lpoptions').read_text(), 'renamed user default migration')
                    assert not called('PrinterDelete'), 'native queue rename must not use separate direct delete calls'
                    ready()
                    assert 'Fixture renamed label' in labels(), 'renamed printer remains selected'
                    click('printers_diagnostics')
                    click('printers_copy_report')
                    report = subprocess.check_output(['wl-paste', '--no-newline'], env={**os.environ, 'XDG_RUNTIME_DIR': str(tmp), 'WAYLAND_DISPLAY': wayland_display_name(tmp)}, timeout=5).decode()
                    assert 'driver=no_output, raw=printed, ruler=printed' in report, 'renamed queue must retain user observations'
                    remove_name = 'Renamed_Label'

                # Removal is a distinct, named confirmation, never a disable.
                click('printers_remove')
                before_remove = set(scheduler.state()['queues'])
                assert not called('PrinterDelete'), calls()
                assert any('Label_Test' in label or 'Fixture renamed label' in label for label in labels()), labels()
                click('printers_remove_confirm')
                wait_for(lambda: called('PrinterDelete', lambda args: args == [remove_name]), 'confirmed queue removal')
                wait_for(lambda: set(scheduler.state()['queues']) == before_remove - {remove_name}, 'confirmed queue removal commit')
                # A missing helper is an explicit read-only state. Disappearance
                # during the page's lifetime cannot fall back to direct admin.
                helper.terminate()
                helper.wait(timeout=5)
                select_printer(ipc, ui, 0)
                click('printers_disable')
                wait_for(lambda: any('cups-pk-helper' in label and ('install' in label.lower() or 'unavailable' in label.lower()) for label in labels()), 'missing helper guidance')
                assert named('printers_add')['is_disabled'] and named('printers_disable')['is_disabled'] and named('printers_connection')['is_disabled'], 'missing helper must disable privileged controls'
                assert scheduler.state()['queues']['Office_Test']['enabled'], scheduler.state()
                click('shortcuts')
                assert not printer_workers(process), 'setup page hide must release worker'
                if any(operation == 0x0016 for operation, _ in scheduler.calls()):
                    wait_for(lambda: any(operation == 0x001b and fields.get('notify-subscription-id') == 23 for operation, fields in scheduler.calls()), 'subscription cancellation on hide')
                count = len(scheduler.calls())
                time.sleep(1)
                assert len(scheduler.calls()) == count, 'hidden setup page must not retain scheduler activity'
            stop_process(process)
            log.flush()
            contents = (tmp / 'compositor.log').read_text()
            assert ' leaked:' not in contents and 'memory address' not in contents, contents[-3000:]
            print('Printer setup, authorization, defaults and confirmed printing passed at scale', scale)
        except Exception:
            if (tmp / 'helper.jsonl').exists():
                Path('/tmp/rediwm-printer-setup-helper.jsonl').write_text((tmp / 'helper.jsonl').read_text())
            Path('/tmp/rediwm-printer-setup-queues.json').write_text(state_path.read_text())
            if log:
                log.flush()
                Path('/tmp/rediwm-printer-setup-compositor.log').write_text((tmp / 'compositor.log').read_text())
            if helper and helper.poll() is not None:
                print(helper.stderr.read())
            raise
        finally:
            if process and process.poll() is None: stop_process(process)
            if log: log.close()
            if helper and helper.poll() is None:
                helper.terminate()
                helper.wait(timeout=5)
            bus.terminate()
            bus.wait(timeout=5)
            scheduler.close()
            network.close()


def tcp_reading(scale):
    with tempfile.TemporaryDirectory(prefix='rediwm-printer-tcp-') as directory:
        tmp = Path(directory)
        scheduler = Scheduler(tmp / 'source.sock')
        endpoint = TcpEndpoint(scheduler)
        process = log = None
        try:
            process, log = spawn_compositor(tmp, scale=scale, config_content='[compositor]\nxwayland = false\n', env_extra={
                'CUPS_SERVER': f'127.0.0.1:{endpoint.server_address[1]}', 'CUPS_USER': scheduler.username, 'CUPS_ENCRYPTION': 'Never',
                'HOME': str(tmp), 'XDG_CONFIG_HOME': str(tmp / 'config'), 'XDG_DATA_HOME': str(tmp / 'data'), 'XDG_CACHE_HOME': str(tmp / 'cache'),
                'DBUS_SESSION_BUS_ADDRESS': '', 'DBUS_SYSTEM_BUS_ADDRESS': '',
                'PIPEWIRE_RUNTIME_DIR': str(tmp), 'PULSE_SERVER': 'unix:/nonexistent-rediwm-printers-test-pulse',
            })
            with IPCClient(tmp, timeout=15) as ipc:
                ui = UIDriver(ipc)
                ipc.open_control_center()
                ui.wait_settled('control_center')
                ui.click(ui.find('printers', panel='control_center'), panel='control_center')
                wait_for(lambda: cups_ready(ui), 'private TCP scheduler', timeout=15)
                assert any(operation == 0x4002 for operation, _ in endpoint.events), endpoint.events
                assert ui.find('printers_add', panel='control_center')['is_disabled'], 'remote scheduler must never administer local CUPS'
                assert ui.find('printers_printer', panel='control_center')['selected_index'] == 0
                assert any(widget.get('label') == 'Label Test' for widget in ui.widgets()), 'remote printer details remain available'
            print('Private TCP scheduler reading and administration isolation passed at scale', scale)
        finally:
            if process: stop_process(process)
            if log: log.close()
            endpoint.close()
            scheduler.close()


if __name__ == '__main__':
    os.umask(0o077)
    scale = os.environ.get('REDIWM_TEST_SCALE', '1')
    run(scale)
    endpoint_errors(scale)
    tcp_reading(scale)
    setup_and_tools(scale, preview=bool(os.environ.get('REDIWM_PRINTERS_PREVIEW')))
