#!/usr/bin/env python3
"""Use the existing single-run EXP executor for the separately named repair plan."""
import execute_t33_target_binding_acceptance as runner

WORK = runner.ROOT / '.build/t32-t33-completion-20261023/exp-signing-acceptance-20261025-r2'
VM = runner.ROOT / '.build/t33t-20261025'


def main():
    runner.WORK = WORK
    runner.VM = VM
    return runner.main()


if __name__ == '__main__':
    raise SystemExit(main())
