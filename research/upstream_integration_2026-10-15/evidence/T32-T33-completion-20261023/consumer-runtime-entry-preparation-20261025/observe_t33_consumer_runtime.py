#!/usr/bin/env python3
"""Run EXP consumer observations only under a separately approved runtime plan."""
import argparse
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import observe_t32_budgeted_runtime as budgeted
from t33_consumer_observations import collect


def configure_observer(module, work, digest):
    module.WORK = work
    module.request = budgeted.transport.request
    plan = module.approved_plan(digest)
    expected = plan.get('expectedBuildVersion')
    if not isinstance(expected, str) or re.fullmatch(r'[0-9]+[A-Z][0-9]+[a-z]?', expected) is None:
        raise ValueError('Explicit expected build required in the approved runtime plan')
    original = module.collect_observations
    module.collect_observations = lambda call, rpc, output, result: collect(
        call, rpc, output, result, expected_build=expected, base_collect=original)
    return module


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-directory', type=Path, required=True)
    parser.add_argument('--execute-approved-runtime-plan', type=budgeted.plan_digest, required=True)
    args = parser.parse_args(argv)
    work = args.work_directory
    if not work.is_absolute() or work.resolve(strict=True) != work or not work.is_dir():
        raise ValueError('An existing absolute, unlinked work directory is required')
    module = configure_observer(budgeted.load_observer(), work, args.execute_approved_runtime_plan)
    previous = sys.argv
    try:
        sys.argv = [str(Path(__file__)), '--execute-approved-runtime-plan', args.execute_approved_runtime_plan]
        return module.main()
    finally:
        sys.argv = previous


if __name__ == '__main__':
    raise SystemExit(main())
