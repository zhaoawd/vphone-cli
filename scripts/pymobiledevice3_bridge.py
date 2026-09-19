import asyncio
import functools
import inspect
import math
import os
import plistlib
import sys
import threading
import time
from collections.abc import Awaitable
from pathlib import Path
from typing import Any, Callable, Optional

from ipsw_parser.ipsw import IPSW
from pymobiledevice3 import usbmux
from pymobiledevice3.exceptions import (
    ConnectionFailedError,
    ConnectionFailedToUsbmuxdError,
    IRecvNoDeviceConnectedError,
    IncorrectModeError,
    PairingError,
)
from pymobiledevice3.irecv import IRecv
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.restore.device import Device
from pymobiledevice3.restore.recovery import Behavior, Recovery
from pymobiledevice3.restore.restore import Restore
import requests
import typer


# pymobiledevice3's own CLI installs coloredlogs at INFO (see its __main__) and
# silences these chatty third-party loggers. Mirror that here so the bridge's
# restore output is the same colorized log stream when run with -v.
_NOISY_LOGGERS = (
    "quic",
    "asyncio",
    "parso.cache",
    "parso.cache.pickle",
    "parso.python.diff",
    "humanfriendly.prompts",
    "blib2to3.pgen2.driver",
    "urllib3.connectionpool",
)


def install_logging(verbose: int) -> None:
    import logging

    level = [logging.WARNING, logging.INFO, logging.DEBUG][min(verbose, 2)]
    try:
        import coloredlogs

        coloredlogs.install(level=level)
    except ImportError:
        logging.basicConfig(level=level)
    for name in _NOISY_LOGGERS:
        logging.getLogger(name).disabled = True


def parse_ecid(value: Optional[str]) -> Optional[int]:
    if not value:
        return None
    raw = value.strip().lower()
    if raw.startswith("0x"):
        raw = raw[2:]
    if not raw:
        raise ValueError("ECID is empty")
    if any(c not in "0123456789abcdef" for c in raw):
        raise ValueError(f"Invalid ECID: {value}")
    return int(raw, 16)


def normalize_udid(value: Optional[str]) -> Optional[str]:
    return None if value is None else value.strip().upper()


def find_restore_dir(vm_dir: Path) -> Path:
    candidates = sorted(p for p in vm_dir.glob("iPhone*_Restore") if p.is_dir())
    if not candidates:
        raise FileNotFoundError(f"No iPhone*_Restore directory found in {vm_dir}")
    if len(candidates) > 1:
        raise RuntimeError(
            "Multiple iPhone*_Restore directories found; keep only one active restore tree"
        )
    return candidates[0]


async def resolve_device(ecid: Optional[int], udid: Optional[str]) -> Device:
    udid_normalized = normalize_udid(udid)

    try:
        devices = [d for d in await usbmux.list_devices() if d.connection_type == "USB"]
    except ConnectionFailedToUsbmuxdError:
        devices = []

    for usb_device in devices:
        serial = normalize_udid(getattr(usb_device, "serial", None))
        if udid_normalized and serial != udid_normalized:
            continue

        try:
            lockdown = await create_using_usbmux(serial=usb_device.serial, connection_type="USB")
        except (ConnectionFailedError, IncorrectModeError, PairingError):
            continue

        lockdown_ecid = int(str(lockdown.ecid), 0)
        if ecid is not None and lockdown_ecid != ecid:
            continue

        return Device(lockdown=lockdown)

    if ecid is None and udid_normalized is not None:
        raise RuntimeError(
            "Target UDID not available over usbmux in lockdownd mode and ECID is unset; "
            "set RESTORE_ECID for DFU/Recovery targeting"
        )

    return Device(irecv=IRecv(ecid=ecid))


async def cmd_usbmux_list(usb_only: bool) -> None:
    devices = await usbmux.list_devices()
    for device in devices:
        if usb_only and getattr(device, "connection_type", None) != "USB":
            continue
        serial = getattr(device, "serial", None)
        if serial:
            print(serial)


def wait_for_irecv(ecid: Optional[int], timeout: int, is_recovery: Optional[bool] = None) -> IRecv:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            return IRecv(ecid=ecid, timeout=2, is_recovery=is_recovery)
        except (IRecvNoDeviceConnectedError, ValueError):
            time.sleep(1)
    mode_label = "recovery" if is_recovery else "dfu/recovery"
    raise TimeoutError(f"Timed out waiting for {mode_label} endpoint")



def derive_shsh_output(vm_dir: Path, ecid: Optional[int]) -> Path:
    tag = f"{ecid:016X}" if ecid is not None else "auto"
    return vm_dir / f"{tag}.shsh"


# ---------------------------------------------------------------------------
# restore-update hardening
#
# pymobiledevice3 (locked at 11.9.2 in dependencies/python-darwin-arm64-3.13.lock)
# fetches restored's URLAsset requests (for example FCS keys) with a bare
# requests.get: no timeout and no retry. The fetch runs in a task created by
# handle_async_data_request_msg and stored in Restore._tasks, which nothing
# awaits. When the fetch raises, the device never receives a reply, and the main
# coroutine waits forever in restored.recv(). The bridge therefore:
#   1. replaces send_url_asset (subclass, same reply protocol) with a fetch that
#      uses explicit timeouts and bounded retries for transient errors;
#   2. watches Restore._tasks and exits non-zero when a task fails.
# When the installed pymobiledevice3 does not have the expected structure, the
# bridge warns and falls back to the upstream behavior.
# ---------------------------------------------------------------------------

URL_ASSET_TIMEOUT = (15.0, 60.0)  # (connect, read) seconds per attempt
URL_ASSET_ATTEMPTS = 4
URL_ASSET_BACKOFF_BASE = 2.0  # waits 2, 4, 8 seconds between attempts
TASK_WATCH_INTERVAL = 0.5
TASK_CANCEL_GRACE = 5.0

# Fault injection for acceptance testing only. Unset (or "0"): no effect.
# "<N>": the first N URL asset fetch attempts in this process raise
# requests.exceptions.SSLError before any network access, so N < URL_ASSET_ATTEMPTS
# exercises a successful retry. "always": every attempt raises, which exhausts the
# retries and must make restore-update exit non-zero.
URL_ASSET_FAULT_ENV = "VPHONE_BRIDGE_FAULT_URL_ASSET"

_URL_ASSET_REPLY_TOKENS = (
    "_get_service_for_data_request",
    "_url_assets_cache",
    '"RequestURL"',
    "requests.get",
    '"ResponseBody"',
    '"ResponseBodyDone"',
    '"ResponseHeaders"',
    '"ResponseStatus"',
    "FMT_BINARY",
    "service.close()",
)


def warn(message: str) -> None:
    print(f"[!] warning: {message}", file=sys.stderr, flush=True)


class URLAssetFaultConfigError(ValueError):
    pass


class URLAssetFetchError(RuntimeError):
    pass


class RestoreBackgroundTaskError(RuntimeError):
    def __init__(self, task_name: str, error: BaseException):
        super().__init__(
            f"background task {task_name!r} raised {type(error).__name__}: {error}"
        )
        self.task_name = task_name
        self.error = error


def parse_url_asset_fault(value: Optional[str]) -> float:
    """Return the number of attempts to fail: 0 disabled, math.inf for "always"."""
    if value is None or not value.strip():
        return 0
    raw = value.strip().lower()
    if raw == "always":
        return math.inf
    if raw.isdigit():
        return int(raw)
    raise URLAssetFaultConfigError(
        f"{URL_ASSET_FAULT_ENV} must be a non-negative integer or 'always', got {value!r}"
    )


class URLAssetFaultInjector:
    def __init__(self, count: float = 0):
        self.remaining = count
        self._lock = threading.Lock()

    @property
    def enabled(self) -> bool:
        return self.remaining > 0

    def maybe_fail(self, url: str) -> None:
        with self._lock:
            if self.remaining <= 0:
                return
            self.remaining -= 1
        raise requests.exceptions.SSLError(
            f"injected by {URL_ASSET_FAULT_ENV} for {url}: UNEXPECTED_EOF_WHILE_READING"
        )


def is_transient_url_error(error: BaseException) -> bool:
    # ConnectionError covers SSLError, ProxyError and ConnectTimeout; Timeout covers
    # ReadTimeout; ChunkedEncodingError is a connection dropped mid-body.
    return isinstance(
        error,
        (
            requests.exceptions.ConnectionError,
            requests.exceptions.Timeout,
            requests.exceptions.ChunkedEncodingError,
        ),
    )


def fetch_url_asset(
    url: str,
    *,
    get: Optional[Callable[..., Any]] = None,
    fault: Optional[URLAssetFaultInjector] = None,
    stop: Optional[threading.Event] = None,
    attempts: int = URL_ASSET_ATTEMPTS,
    timeout: tuple[float, float] = URL_ASSET_TIMEOUT,
    backoff_base: float = URL_ASSET_BACKOFF_BASE,
    log: Optional[Callable[[str], None]] = None,
) -> Any:
    """GET url with timeouts; retry transient errors and HTTP 5xx.

    Returns the response (including the last 5xx response when retries are
    exhausted, which the caller forwards like upstream does for non-200 codes).
    Raises URLAssetFetchError after the last transient exception, and re-raises
    non-transient exceptions immediately.
    """
    get = get or requests.get
    stop = stop or threading.Event()
    log = log or warn
    for attempt in range(1, attempts + 1):
        try:
            if fault is not None:
                fault.maybe_fail(url)
            response = get(url, timeout=timeout)
        except Exception as error:
            if not is_transient_url_error(error):
                raise
            if attempt == attempts:
                raise URLAssetFetchError(
                    f"URLAsset {url}: {attempts} attempts failed; last error: "
                    f"{type(error).__name__}: {error}"
                ) from error
            reason = f"{type(error).__name__}: {error}"
        else:
            if response.status_code < 500 or attempt == attempts:
                return response
            reason = f"HTTP {response.status_code}"
        delay = backoff_base * (2 ** (attempt - 1))
        log(f"URLAsset {url} attempt {attempt}/{attempts} failed ({reason}); retrying in {delay:g}s")
        if stop.wait(delay):
            raise URLAssetFetchError(f"URLAsset {url}: retry cancelled")
    raise AssertionError("unreachable")


async def send_url_asset_with_retry(
    restore: Any,
    message: dict[str, Any],
    fetch: Callable[..., Any] = fetch_url_asset,
    fault: Optional[URLAssetFaultInjector] = None,
) -> None:
    """Upstream Restore.send_url_asset (pymobiledevice3 11.9.2) with a retrying fetch."""
    restore.logger.info(f"send_url_asset: {message}")
    service = await restore._get_service_for_data_request(message)
    arguments = message["Arguments"]
    assert arguments["RequestMethod"] == "GET"
    url = arguments["RequestURL"]

    if url in restore._url_assets_cache:
        restore.logger.debug("Using cached URLAsset")
        response = restore._url_assets_cache[url]
    else:
        stop = threading.Event()
        call = functools.partial(fetch, url, fault=fault, stop=stop, log=restore.logger.warning)
        try:
            response = await asyncio.get_running_loop().run_in_executor(None, call)
        except asyncio.CancelledError:
            stop.set()
            raise
        # A cached 5xx would be replayed for later requests of the same URL.
        if response.status_code < 500:
            restore._url_assets_cache[url] = response

    if response.status_code != 200:
        restore.logger.error(
            f"Got status code {response.status_code} from URLAsset {url}:\n{response.headers}\n\n{response.text}"
        )
    await service.send_plist(
        {
            "ResponseBody": response.content,
            "ResponseBodyDone": True,
            "ResponseHeaders": dict(response.headers),
            "ResponseStatus": response.status_code,
        },
        fmt=plistlib.FMT_BINARY,
    )
    await service.close()


def check_url_asset_compat(restore_cls: Any) -> list[str]:
    """Return reasons the upstream send_url_asset differs from the replaced version."""
    problems = []
    for name in ("send_url_asset", "_get_service_for_data_request", "update"):
        if not callable(getattr(restore_cls, name, None)):
            problems.append(f"{restore_cls.__name__}.{name} is missing")
    if problems:
        return problems
    original = inspect.unwrap(restore_cls.send_url_asset)
    if not inspect.iscoroutinefunction(original):
        problems.append("send_url_asset is not a coroutine function")
    if list(inspect.signature(original).parameters) != ["self", "message"]:
        problems.append(f"send_url_asset signature is {inspect.signature(original)}")
    try:
        source = inspect.getsource(original)
    except (OSError, TypeError) as error:
        problems.append(f"send_url_asset source unavailable ({error})")
    else:
        missing = [token for token in _URL_ASSET_REPLY_TOKENS if token not in source]
        if missing:
            problems.append(f"send_url_asset no longer contains {', '.join(missing)}")
    return problems


def make_retrying_restore_class(base: Any) -> Any:
    class VPhoneRestore(base):
        def __init__(self, *args: Any, url_asset_fault: Optional[URLAssetFaultInjector] = None, **kwargs: Any):
            self._vphone_url_asset_fault = url_asset_fault
            super().__init__(*args, **kwargs)

        async def send_url_asset(self, message: dict[str, Any]) -> None:
            await send_url_asset_with_retry(self, message, fault=self._vphone_url_asset_fault)

    return VPhoneRestore


def build_restore(
    ipsw: Any,
    device: Any,
    *,
    tss: Any,
    behavior: Any,
    fault: URLAssetFaultInjector,
    restore_cls: Any = None,
) -> Any:
    base = restore_cls or Restore
    problems = check_url_asset_compat(base)
    if problems:
        warn(
            "URLAsset retry disabled; pymobiledevice3 Restore does not match the expected "
            "structure: " + "; ".join(problems)
        )
        if fault.enabled:
            warn(f"{URL_ASSET_FAULT_ENV} has no effect while URLAsset retry is disabled")
        return base(ipsw, device, tss=tss, behavior=behavior, ignore_fdr=False)

    cls = make_retrying_restore_class(base)
    restore = cls(ipsw, device, tss=tss, behavior=behavior, ignore_fdr=False, url_asset_fault=fault)
    handlers = getattr(restore, "_data_request_handlers", None)
    handler = handlers.get("URLAsset") if isinstance(handlers, dict) else None
    if getattr(handler, "__func__", None) is not cls.send_url_asset:
        warn("URLAsset data requests are not routed to Restore.send_url_asset; URLAsset retry may be inactive")
    if fault.enabled:
        warn(f"{URL_ASSET_FAULT_ENV} active: {fault.remaining} URL asset fetch attempt(s) will fail")
    return restore


def restore_task_list(restore: Any) -> Optional[list]:
    tasks = getattr(restore, "_tasks", None)
    return tasks if isinstance(tasks, list) else None


def first_failed_task(tasks: list) -> Optional[tuple[str, BaseException]]:
    for task in list(tasks):
        if not isinstance(task, asyncio.Future) or not task.done() or task.cancelled():
            continue
        error = task.exception()
        if error is not None:
            name = task.get_name() if isinstance(task, asyncio.Task) else repr(task)
            return name, error
    return None


async def _cancel_and_wait(tasks: list) -> None:
    pending = [t for t in tasks if isinstance(t, asyncio.Future) and not t.done()]
    for task in pending:
        task.cancel()
    if pending:
        await asyncio.wait(pending, timeout=TASK_CANCEL_GRACE)


async def run_update_with_task_watchdog(
    restore: Any, tasks: list, poll_interval: float = TASK_WATCH_INTERVAL
) -> None:
    """Run restore.update(); fail fast when a task in restore._tasks raises.

    Once update() has returned, later task failures (for example the FDR listener
    losing its connection when the device reboots) are not reported.
    """
    update_task = asyncio.ensure_future(restore.update())
    try:
        while True:
            await asyncio.wait({update_task}, timeout=poll_interval)
            failed = first_failed_task(tasks)
            if failed is not None:
                name, error = failed
                await _cancel_and_wait([update_task])
                await _cancel_and_wait(tasks)
                raise RestoreBackgroundTaskError(name, error) from error
            if update_task.done():
                update_task.result()
                return
    finally:
        if not update_task.done():
            await _cancel_and_wait([update_task])


async def cmd_restore_get_shsh(
    vm_dir: Path, ecid: Optional[int], udid: Optional[str], out: Optional[Path]
) -> None:
    restore_dir = find_restore_dir(vm_dir)
    ipsw = IPSW.create_from_path(str(restore_dir))
    device = await resolve_device(ecid, udid)
    tss = await Recovery(ipsw, device, behavior=Behavior.Erase).fetch_tss_record()

    out_path = out or derive_shsh_output(vm_dir, device.get_ecid_value())
    with out_path.open("wb") as handle:
        plistlib.dump(tss, handle)

    print(f"[+] SHSH saved: {out_path}")


async def cmd_restore_update(
    vm_dir: Path,
    ecid: Optional[int],
    udid: Optional[str],
    erase: bool,
    tss_path: Optional[Path] = None,
) -> None:
    fault = URLAssetFaultInjector(parse_url_asset_fault(os.environ.get(URL_ASSET_FAULT_ENV)))
    restore_dir = find_restore_dir(vm_dir)
    ipsw = IPSW.create_from_path(str(restore_dir))
    behavior = Behavior.Erase if erase else Behavior.Update
    device = await resolve_device(ecid, udid)
    tss = None
    if tss_path is not None:
        with tss_path.open("rb") as handle:
            tss = plistlib.load(handle)
        print(f"[+] Using cached SHSH: {tss_path}")
    restore = build_restore(ipsw, device, tss=tss, behavior=behavior, fault=fault)
    tasks = restore_task_list(restore)
    if tasks is None:
        warn(
            "Restore._tasks is not a task list in this pymobiledevice3 version; "
            "background task failures will not stop restore-update"
        )
        await restore.update()
        return
    await run_update_with_task_watchdog(restore, tasks)


def require_ecid(value: str) -> Optional[int]:
    try:
        return parse_ecid(value)
    except ValueError as exc:
        raise typer.BadParameter(str(exc)) from exc


app = typer.Typer(help="pymobiledevice3 bridge for vphone", pretty_exceptions_enable=False)


@app.command("usbmux-list", help="List usbmux UDIDs")
def usbmux_list_command(
    usb_only: bool = typer.Option(
        True,
        "--usb-only/--no-usb-only",
        help="Include network devices with --no-usb-only.",
    ),
) -> Awaitable[None]:
    return cmd_usbmux_list(usb_only=usb_only)


@app.command("recovery-probe", help="Probe for DFU/recovery endpoint")
def recovery_probe_command(
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    timeout: int = typer.Option(2, help="Probe timeout in seconds"),
) -> None:
    parsed_ecid = require_ecid(ecid)
    wait_for_irecv(parsed_ecid, timeout=timeout)


@app.command("restore-get-shsh", help="Fetch SHSH from prepared restore dir")
def restore_get_shsh_command(
    vm_dir: Path = typer.Option(
        Path("."),
        help="VM directory",
        exists=False,
        file_okay=False,
        dir_okay=True,
    ),
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    udid: Optional[str] = typer.Option(None, help="Target USB UDID"),
    out: Optional[Path] = typer.Option(
        None,
        help="Output SHSH path",
        exists=False,
        file_okay=True,
        dir_okay=False,
    ),
    verbose: int = typer.Option(
        0, "--verbose", "-v", count=True, help="Increase log verbosity (-v info, -vv debug)."
    ),
) -> Awaitable[None]:
    install_logging(verbose)
    return cmd_restore_get_shsh(vm_dir, require_ecid(ecid), udid, out)


@app.command("restore-update", help="Run erase/update restore from prepared dir")
def restore_update_command(
    vm_dir: Path = typer.Option(
        Path("."),
        help="VM directory",
        exists=False,
        file_okay=False,
        dir_okay=True,
    ),
    ecid: Optional[str] = typer.Option(None, help="Hex ECID (with/without 0x)"),
    udid: Optional[str] = typer.Option(None, help="Target USB UDID"),
    erase: bool = typer.Option(True, "--erase/--no-erase", help="Run update-in-place with --no-erase."),
    tss: Optional[Path] = typer.Option(
        None,
        help="Cached SHSH plist for offline restore (skips Apple TSS request).",
        exists=False,
        file_okay=True,
        dir_okay=False,
    ),
    verbose: int = typer.Option(
        0, "--verbose", "-v", count=True, help="Increase log verbosity (-v info, -vv debug)."
    ),
) -> Awaitable[None]:
    install_logging(verbose)
    return cmd_restore_update(vm_dir, require_ecid(ecid), udid, erase=erase, tss_path=tss)


async def main(argv: list[str]) -> None:
    result = app(args=argv, prog_name="pymobiledevice3_bridge.py", standalone_mode=False)
    if inspect.isawaitable(result):
        await result


def run_cli(argv: list[str]) -> int:
    try:
        asyncio.run(main(argv))
    except RestoreBackgroundTaskError as exc:
        print(f"[-] restore-update failed: {exc}", file=sys.stderr, flush=True)
        return 1
    except URLAssetFaultConfigError as exc:
        print(f"[-] {exc}", file=sys.stderr, flush=True)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(run_cli(sys.argv[1:]))
