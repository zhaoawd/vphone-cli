#!/usr/bin/env python3
"""Run the approved observer with a 100-second outer RPC budget."""
import argparse
import importlib.util
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import t32_runtime_rpc_transport as transport


def plan_digest(value):
    if re.fullmatch(r'[0-9a-f]{64}', value) is None:
        raise argparse.ArgumentTypeError('An explicit SHA-256 plan digest is required')
    return value


def load_observer():
    source = Path(__file__).with_name('observe_t32_runtime.py')
    spec = importlib.util.spec_from_file_location('t32_budgeted_observer', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-directory', type=Path, required=True)
    parser.add_argument('--execute-approved-runtime-plan', type=plan_digest, required=True)
    args = parser.parse_args(argv)
    work = args.work_directory
    if not work.is_absolute() or work.resolve(strict=True) != work or not work.is_dir():
        raise ValueError('An existing absolute, unlinked work directory is required')
    module = load_observer()
    module.WORK = work
    module.request = transport.request
    original_argv = sys.argv
    try:
        sys.argv = [str(Path(__file__)), '--execute-approved-runtime-plan',
                    args.execute_approved_runtime_plan]
        return module.main()
    finally:
        sys.argv = original_argv


if __name__ == '__main__':
    raise SystemExit(main())
