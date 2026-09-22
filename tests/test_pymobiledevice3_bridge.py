"""restore-update bridge: URL asset retries and background task failure handling.

No device is contacted. End-to-end cases run the real script entry point in a
child process with pymobiledevice3's device, usbmux, IPSW and Restore objects
replaced before the script imports them.
"""
import asyncio
import contextlib
import importlib.util
import io
import math
from pathlib import Path
import os
import plistlib
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
import unittest.mock

import requests

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'scripts/pymobiledevice3_bridge.py'
CHILD_TIMEOUT = 45

CHILD_PRELUDE = textwrap.dedent('''
    import asyncio, runpy, sys
    import requests
    import ipsw_parser.ipsw as ipsw_mod
    import pymobiledevice3.irecv as irecv_mod
    import pymobiledevice3.restore.device as device_mod
    import pymobiledevice3.restore.restore as restore_mod
    import pymobiledevice3.usbmux as usbmux_mod

    async def _no_devices():
        return []

    usbmux_mod.list_devices = _no_devices
    irecv_mod.IRecv = lambda **kwargs: object()
    device_mod.Device = lambda **kwargs: object()
    ipsw_mod.IPSW.create_from_path = staticmethod(lambda path: object())

    async def _completed():
        return None

    class FakeRestore:
        def __init__(self, ipsw, device, tss=None, behavior=None, ignore_fdr=False):
            self._tasks = []
''')

CHILD_RUN = textwrap.dedent('''
    restore_mod.Restore = FakeRestore
    sys.argv = [sys.argv[1], 'restore-update', '--vm-dir', sys.argv[2]]
    runpy.run_path(sys.argv[0], run_name='__main__')
''')


def run_child(update_body, timeout=CHILD_TIMEOUT, extra_env=None):
    source = (CHILD_PRELUDE + textwrap.indent(textwrap.dedent(update_body), '    ')
              + CHILD_RUN)
    with tempfile.TemporaryDirectory() as temporary:
        vm_dir = Path(temporary)
        (vm_dir / 'iPhone17,3_26.0_Restore').mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith('VPHONE_BRIDGE_FAULT_')}
        env.update(extra_env or {})
        return subprocess.run([sys.executable, '-B', '-c', source, str(BRIDGE), str(vm_dir)],
                              capture_output=True, text=True, timeout=timeout, env=env, cwd=ROOT)


class BridgeProcessTests(unittest.TestCase):
    def test_background_task_failure_exits_nonzero_instead_of_hanging(self):
        # Reproduces the 2026-09-17 hang: an async data request task raises while the
        # main coroutine waits on restored.recv() without a timeout.
        result = run_child('''
            async def update(self):
                async def fail():
                    await asyncio.sleep(0.05)
                    raise requests.exceptions.SSLError('UNEXPECTED_EOF_WHILE_READING')
                self._tasks.append(asyncio.create_task(_completed(), name='FDR-FDR_CTRL'))
                self._tasks.append(asyncio.create_task(fail(), name='AsyncDataRequestMsg-URLAsset'))
                await asyncio.Event().wait()
        ''')
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn('AsyncDataRequestMsg-URLAsset', result.stderr)
        self.assertIn('SSLError', result.stderr)
        self.assertIn('UNEXPECTED_EOF_WHILE_READING', result.stderr)
        # FakeRestore has no send_url_asset: the bridge must say retry is disabled.
        self.assertIn('URLAsset retry disabled', result.stderr)

    def test_completed_background_tasks_do_not_fail_restore(self):
        result = run_child('''
            async def update(self):
                self._tasks.append(asyncio.create_task(_completed(), name='FDR-FDR_CTRL'))
                self._tasks.append(asyncio.create_task(_completed(), name='AsyncDataRequestMsg-URLAsset'))
                await asyncio.sleep(1.2)
        ''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('restore-update failed', result.stderr)

    def test_invalid_fault_value_exits_before_restore(self):
        result = run_child('''
            async def update(self):
                raise AssertionError('restore must not start')
        ''', extra_env={'VPHONE_BRIDGE_FAULT_URL_ASSET': 'sometimes'})
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('VPHONE_BRIDGE_FAULT_URL_ASSET', result.stderr)


def load_bridge():
    spec = importlib.util.spec_from_file_location('pymobiledevice3_bridge_under_test', BRIDGE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bridge = load_bridge()


class FakeResponse:
    def __init__(self, status=200, content=b'key', headers=None):
        self.status_code = status
        self.content = content
        self.headers = headers or {'Content-Type': 'application/octet-stream'}
        self.text = content.decode(errors='replace')


class FakeGet:
    """Returns or raises the queued outcomes in order; records call arguments."""

    def __init__(self, *outcomes):
        self.outcomes = list(outcomes)
        self.calls = []

    def __call__(self, url, **kwargs):
        self.calls.append((url, kwargs))
        outcome = self.outcomes.pop(0) if len(self.outcomes) > 1 else self.outcomes[0]
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


def ssl_error():
    return requests.exceptions.SSLError('UNEXPECTED_EOF_WHILE_READING')


def fetch(get, **kwargs):
    logs = []
    kwargs.setdefault('backoff_base', 0)
    return bridge.fetch_url_asset('https://fcs.example/key', get=get, log=logs.append, **kwargs), logs


class FetchURLAssetTests(unittest.TestCase):
    def test_transient_failure_is_retried_with_timeouts(self):
        ok = FakeResponse()
        get = FakeGet(ssl_error(), requests.exceptions.ReadTimeout('slow'), ok)
        response, logs = fetch(get)
        self.assertIs(response, ok)
        self.assertEqual(len(get.calls), 3)
        self.assertTrue(all(kw == {'timeout': bridge.URL_ASSET_TIMEOUT} for _, kw in get.calls))
        self.assertEqual(len(logs), 2)
        self.assertIn('SSLError', logs[0])

    def test_exhausted_retries_raise_fetch_error(self):
        get = FakeGet(ssl_error())
        with self.assertRaises(bridge.URLAssetFetchError) as caught:
            fetch(get)
        self.assertEqual(len(get.calls), bridge.URL_ASSET_ATTEMPTS)
        self.assertIsInstance(caught.exception.__cause__, requests.exceptions.SSLError)

    def test_non_transient_errors_are_not_retried(self):
        for error in (requests.exceptions.InvalidURL('bad'), ValueError('bug')):
            get = FakeGet(error)
            with self.assertRaises(type(error)):
                fetch(get)
            self.assertEqual(len(get.calls), 1)

    def test_4xx_is_returned_without_retry(self):
        get = FakeGet(FakeResponse(404))
        response, _ = fetch(get)
        self.assertEqual(response.status_code, 404)
        self.assertEqual(len(get.calls), 1)

    def test_5xx_is_retried_and_last_response_returned(self):
        get = FakeGet(FakeResponse(503), FakeResponse(200))
        response, _ = fetch(get)
        self.assertEqual((response.status_code, len(get.calls)), (200, 2))
        get = FakeGet(FakeResponse(502))
        response, _ = fetch(get)
        self.assertEqual((response.status_code, len(get.calls)), (502, bridge.URL_ASSET_ATTEMPTS))

    def test_backoff_is_exponential(self):
        waits = []

        class RecordingStop(threading.Event):
            def wait(self, timeout=None):
                waits.append(timeout)
                return False

        with self.assertRaises(bridge.URLAssetFetchError):
            fetch(FakeGet(ssl_error()), backoff_base=2.0, stop=RecordingStop())
        self.assertEqual(waits, [2.0, 4.0, 8.0])

    def test_stop_event_ends_retries(self):
        stop = threading.Event()
        stop.set()
        get = FakeGet(ssl_error())
        with self.assertRaises(bridge.URLAssetFetchError):
            fetch(get, stop=stop)
        self.assertEqual(len(get.calls), 1)

    def test_fault_injection_counts_attempts(self):
        get = FakeGet(FakeResponse())
        response, logs = fetch(get, fault=bridge.URLAssetFaultInjector(1))
        self.assertEqual(response.status_code, 200)
        self.assertEqual((len(get.calls), len(logs)), (1, 1))
        self.assertIn(bridge.URL_ASSET_FAULT_ENV, logs[0])

        get = FakeGet(FakeResponse())
        with self.assertRaises(bridge.URLAssetFetchError):
            fetch(get, fault=bridge.URLAssetFaultInjector(math.inf))
        self.assertEqual(get.calls, [])

    def test_fault_value_parsing(self):
        for value, expected in ((None, 0), ('', 0), ('0', 0), (' 3 ', 3),
                                ('always', math.inf), ('ALWAYS', math.inf)):
            self.assertEqual(bridge.parse_url_asset_fault(value), expected, value)
        for value in ('-1', '1.5', 'yes'):
            with self.assertRaises(bridge.URLAssetFaultConfigError):
                bridge.parse_url_asset_fault(value)
        self.assertFalse(bridge.URLAssetFaultInjector(0).enabled)


class FakeLogger:
    def __init__(self):
        self.records = []

    def __getattr__(self, level):
        return lambda message: self.records.append((level, message))


class FakeService:
    def __init__(self):
        self.sent = []
        self.closed = False

    async def send_plist(self, payload, fmt=None):
        self.sent.append((payload, fmt))

    async def close(self):
        self.closed = True


class FakeRestoreForURLAsset:
    def __init__(self):
        self.logger = FakeLogger()
        self._url_assets_cache = {}
        self.service = FakeService()

    async def _get_service_for_data_request(self, message):
        return self.service


def url_asset_message(url='https://fcs.example/key'):
    return {'DataType': 'URLAsset', 'Arguments': {'RequestMethod': 'GET', 'RequestURL': url}}


class SendURLAssetTests(unittest.TestCase):
    def run_send(self, restore, get):
        def fetcher(url, **kwargs):
            kwargs['backoff_base'] = 0
            return bridge.fetch_url_asset(url, get=get, **kwargs)
        asyncio.run(bridge.send_url_asset_with_retry(restore, url_asset_message(), fetch=fetcher))

    def test_retry_success_replies_and_closes_like_upstream(self):
        restore = FakeRestoreForURLAsset()
        response = FakeResponse(content=b'fcs-key', headers={'ETag': 'x'})
        get = FakeGet(ssl_error(), response)
        self.run_send(restore, get)
        self.assertEqual(restore.service.sent, [({
            'ResponseBody': b'fcs-key',
            'ResponseBodyDone': True,
            'ResponseHeaders': {'ETag': 'x'},
            'ResponseStatus': 200,
        }, plistlib.FMT_BINARY)])
        self.assertTrue(restore.service.closed)
        self.assertIs(restore._url_assets_cache['https://fcs.example/key'], response)

        again = FakeRestoreForURLAsset()
        again._url_assets_cache = restore._url_assets_cache
        self.run_send(again, FakeGet(AssertionError('cached URL must not be fetched')))
        self.assertTrue(again.service.closed)

    def test_exhausted_retry_raises_without_reply(self):
        restore = FakeRestoreForURLAsset()
        with self.assertRaises(bridge.URLAssetFetchError):
            self.run_send(restore, FakeGet(ssl_error()))
        self.assertEqual(restore.service.sent, [])
        self.assertEqual(restore._url_assets_cache, {})

    def test_5xx_is_forwarded_but_not_cached(self):
        restore = FakeRestoreForURLAsset()
        self.run_send(restore, FakeGet(FakeResponse(500)))
        self.assertEqual(restore.service.sent[0][0]['ResponseStatus'], 500)
        self.assertEqual(restore._url_assets_cache, {})


class CompatibleRestoreBase:
    """Mimics the parts of pymobiledevice3 11.9.2 Restore that the bridge relies on."""

    def __init__(self, ipsw, device, tss=None, behavior=None, ignore_fdr=False):
        self._tasks = []
        self._data_request_handlers = {'URLAsset': self.send_url_asset}
        self._url_assets_cache = {}
        self.logger = FakeLogger()
        self.service = FakeService()

    async def update(self):
        return None

    async def _get_service_for_data_request(self, message):
        return self.service

    async def send_url_asset(self, message):
        service = await self._get_service_for_data_request(message)
        url = message["Arguments"]["RequestURL"]
        response = self._url_assets_cache.get(url) or requests.get(url)
        await service.send_plist({"ResponseBody": 0, "ResponseBodyDone": 1, "ResponseHeaders": 2,
                                  "ResponseStatus": 3}, fmt=plistlib.FMT_BINARY)
        await service.close()


class RestoreCompatibilityTests(unittest.TestCase):
    def build(self, cls, fault=0):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            restore = bridge.build_restore(object(), object(), tss=None, behavior=None,
                                           fault=bridge.URLAssetFaultInjector(fault), restore_cls=cls)
        return restore, stderr.getvalue()

    def test_locked_pymobiledevice3_matches_expected_structure(self):
        self.assertEqual(bridge.check_url_asset_compat(bridge.Restore), [])

    def test_compatible_base_is_subclassed_and_routed(self):
        restore, stderr = self.build(CompatibleRestoreBase)
        self.assertIsInstance(restore, CompatibleRestoreBase)
        self.assertIsNot(type(restore), CompatibleRestoreBase)
        handler = restore._data_request_handlers['URLAsset']
        self.assertIs(handler.__func__, type(restore).send_url_asset)
        self.assertEqual(stderr, '')

    def test_fault_injection_is_announced(self):
        _, stderr = self.build(CompatibleRestoreBase, fault=math.inf)
        self.assertIn('VPHONE_BRIDGE_FAULT_URL_ASSET active', stderr)

    def test_mismatched_structure_falls_back_with_warning(self):
        class MissingMethod(CompatibleRestoreBase):
            send_url_asset = None

        class ChangedSignature(CompatibleRestoreBase):
            async def send_url_asset(self, message, retries):
                return await super().send_url_asset(message)

        class ChangedReply(CompatibleRestoreBase):
            async def send_url_asset(self, message):
                service = await self._get_service_for_data_request(message)
                await service.send_plist({"Body": b""})

        for cls in (MissingMethod, ChangedSignature, ChangedReply):
            restore, stderr = self.build(cls, fault=1)
            self.assertIs(type(restore), cls)
            self.assertIn('URLAsset retry disabled', stderr)
            self.assertIn('has no effect', stderr)

    def test_unrouted_handler_warns(self):
        class Unrouted(CompatibleRestoreBase):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                self._data_request_handlers = {}

        _, stderr = self.build(Unrouted)
        self.assertIn('not routed', stderr)

    def test_missing_task_list_is_detected(self):
        class NoTasks:
            pass
        self.assertIsNone(bridge.restore_task_list(NoTasks()))
        self.assertEqual(bridge.restore_task_list(CompatibleRestoreBase(None, None)), [])


class WatchdogTests(unittest.TestCase):
    def run_watchdog(self, update, timeout=5):
        class Restore:
            def __init__(self):
                self._tasks = []

        restore = Restore()
        restore.update = lambda: update(restore)

        async def main():
            return await asyncio.wait_for(
                bridge.run_update_with_task_watchdog(restore, restore._tasks, poll_interval=0.02), timeout)

        return asyncio.run(main())

    def test_failed_task_cancels_update(self):
        state = {}

        async def update(restore):
            async def fail():
                raise bridge.URLAssetFetchError('URLAsset x: 4 attempts failed')
            restore._tasks.append(asyncio.create_task(fail(), name='AsyncDataRequestMsg-URLAsset'))
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                state['cancelled'] = True
                raise

        started = time.monotonic()
        with self.assertRaises(bridge.RestoreBackgroundTaskError) as caught:
            self.run_watchdog(update)
        self.assertLess(time.monotonic() - started, 2)
        self.assertTrue(state.get('cancelled'))
        self.assertEqual(caught.exception.task_name, 'AsyncDataRequestMsg-URLAsset')
        self.assertIn('URLAssetFetchError', str(caught.exception))

    def test_completed_and_cancelled_tasks_are_not_failures(self):
        async def update(restore):
            async def done():
                return 1

            async def forever():
                await asyncio.Event().wait()
            restore._tasks.append(asyncio.create_task(done(), name='FDR-FDR_CTRL'))
            cancelled = asyncio.create_task(forever(), name='AsyncDataRequestMsg-X')
            restore._tasks.append(cancelled)
            await asyncio.sleep(0.05)
            cancelled.cancel()
            await asyncio.sleep(0.1)
            return 'finished'

        self.assertIsNone(self.run_watchdog(update))

    def test_task_failure_after_update_returns_is_ignored(self):
        async def update(restore):
            async def fail_later():
                await asyncio.sleep(0.01)
                raise ConnectionAbortedError('device rebooted')
            restore._tasks.append(asyncio.create_task(fail_later(), name='FDR-FDR_CTRL'))

        self.run_watchdog(update)

    def test_task_failure_before_update_returns_wins_same_poll_cycle(self):
        async def update(restore):
            async def fail_now():
                raise bridge.URLAssetFetchError('URLAsset failed before update returned')

            restore._tasks.append(asyncio.create_task(
                fail_now(), name='AsyncDataRequestMsg-URLAsset'))
            # Both tasks are done before the watchdog wakes. The background
            # failure still has to win over update() returning successfully.
            await asyncio.sleep(0)

        with self.assertRaises(bridge.RestoreBackgroundTaskError) as caught:
            self.run_watchdog(update)
        self.assertEqual(caught.exception.task_name, 'AsyncDataRequestMsg-URLAsset')
        self.assertIn('URLAssetFetchError', str(caught.exception))

    def test_update_exception_propagates(self):
        async def update(restore):
            raise RuntimeError('restore failed')

        with self.assertRaisesRegex(RuntimeError, 'restore failed'):
            self.run_watchdog(update)


class URLAssetRestoreIntegrationTests(unittest.TestCase):
    """Subclassed Restore + fault injection + watchdog, as wired by cmd_restore_update."""

    def run_restore(self, fault):
        class Base(CompatibleRestoreBase):
            async def update(self):
                handler = self._data_request_handlers['URLAsset']
                self._tasks.append(asyncio.create_task(handler(url_asset_message()),
                                                       name='AsyncDataRequestMsg-URLAsset'))
                while not self.service.closed:
                    await asyncio.sleep(0.01)

        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            restore = bridge.build_restore(object(), object(), tss=None, behavior=None,
                                           fault=bridge.URLAssetFaultInjector(fault), restore_cls=Base)
        get = FakeGet(FakeResponse(content=b'fcs-key'))
        kwdefaults = dict(bridge.fetch_url_asset.__kwdefaults__, backoff_base=0)
        with unittest.mock.patch.object(bridge.fetch_url_asset, '__kwdefaults__', kwdefaults), \
                unittest.mock.patch.object(bridge.requests, 'get', get):
            async def main():
                await asyncio.wait_for(bridge.run_update_with_task_watchdog(
                    restore, bridge.restore_task_list(restore), poll_interval=0.02), 5)
            asyncio.run(main())
        return restore, get

    def test_single_injected_fault_is_retried_and_restore_completes(self):
        restore, get = self.run_restore(1)
        self.assertEqual(len(get.calls), 1)
        self.assertEqual(restore.service.sent[0][0]['ResponseBody'], b'fcs-key')
        self.assertTrue(restore.service.closed)

    def test_always_failing_fetch_fails_restore_in_bounded_time(self):
        started = time.monotonic()
        with self.assertRaises(bridge.RestoreBackgroundTaskError) as caught:
            self.run_restore(math.inf)
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(caught.exception.task_name, 'AsyncDataRequestMsg-URLAsset')
        self.assertIsInstance(caught.exception.error, bridge.URLAssetFetchError)


if __name__ == '__main__':
    unittest.main()
