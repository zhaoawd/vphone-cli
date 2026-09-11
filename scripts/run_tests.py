#!/usr/bin/env python3
"""Run local tests without booting a VM or modifying firmware inputs."""

import argparse
import os
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FIRMWARE_FILES = (
    "raw_payloads/avpbooter.bin",
    "raw_payloads/ibss.bin",
    "raw_payloads/ibec.bin",
    "raw_payloads/llb.bin",
    "raw_payloads/txm.bin",
    "raw_payloads/kernelcache.bin",
    "reference_patches/avpbooter.json",
    "reference_patches/ibss.json",
    "reference_patches/ibec.json",
    "reference_patches/llb.json",
    "reference_patches/txm.json",
    "reference_patches/txm_dev.json",
    "reference_patches/kernelcache.json",
    "reference_patches/ibss_jb.json",
    "reference_patches/kernelcache_jb.json",
    "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p",
    "Firmware/txm.iphoneos.research.im4p",
)


def fixture_directory():
    return Path(os.environ.get("VPHONE_TEST_FIXTURES") or
                ROOT / "ipsws/patch_refactor_input").resolve()


def check_fixtures():
    base = fixture_directory()
    missing = [name for name in FIRMWARE_FILES
               if not (base / name).is_file() or (base / name).stat().st_size == 0]
    if missing:
        print(f"Missing or empty firmware fixtures in {base}:", file=sys.stderr)
        for name in missing:
            print(f"  {name}", file=sys.stderr)
        print("Firmware tests not executed. Set VPHONE_TEST_FIXTURES to a complete fixture directory.",
              file=sys.stderr)
        return False
    print(f"Fixture preflight: {len(FIRMWARE_FILES)} nonempty files in {base}; "
          "firmware tests not executed yet.", flush=True)
    return True


def run(command, env=None):
    print(f"+ {shlex.join(map(str, command))}", flush=True)
    subprocess.run(command, cwd=ROOT, env=env, check=True)


def run_python():
    python = ROOT / ".venv/bin/python3"
    if not python.is_file():
        raise RuntimeError("Project .venv is missing. Run make setup_venv first.")
    run([python, "-B", ROOT / "scripts/check_python_runtime.py"])
    run([python, "-B", "-m", "unittest", "discover", "-s", "tests", "-p", "test_*.py", "-v"])


def run_swift(firmware=False):
    env = os.environ.copy()
    # Real firmware selectors must not activate acceptance tests in a fast run.
    # The fixture suite also starts clean, then enables only its declared target.
    for name in list(env):
        if name.startswith(("VPHONE_TEST_", "VPHONE_LESS_", "VPHONE_C4_")):
            del env[name]
    if firmware:
        env["VPHONE_TEST_FIXTURES"] = str(fixture_directory())
    cache = ROOT / ".build/test-cache"
    modules = ROOT / ".build/test-module-cache"
    cache.mkdir(parents=True, exist_ok=True)
    modules.mkdir(parents=True, exist_ok=True)
    env.setdefault("CLANG_MODULE_CACHE_PATH", str(modules))
    env.setdefault("SWIFT_MODULECACHE_PATH", str(modules))
    # Separate targets prevent new fixture tests from leaking into the fast suite.
    selection = "--filter" if firmware else "--skip"
    run(["swift", "test", "--disable-sandbox", "--cache-path", cache,
         selection, "FirmwareIntegrationTests"], env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", nargs="?", default="fast",
                        choices=("fast", "python", "swift", "firmware", "fixtures"))
    args = parser.parse_args()
    try:
        if args.suite in ("firmware", "fixtures"):
            if not check_fixtures():
                return 1
            if args.suite == "firmware":
                run_swift(firmware=True)
        else:
            if args.suite in ("fast", "python"):
                run_python()
            if args.suite in ("fast", "swift"):
                run_swift()
    except subprocess.CalledProcessError as error:
        return error.returncode if error.returncode > 0 else 1
    except (OSError, RuntimeError) as error:
        print(f"Test environment error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
