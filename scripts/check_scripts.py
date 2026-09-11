#!/usr/bin/env python3
"""Parse tracked Python and shell scripts without executing them."""
import argparse
import ast
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', help='Explicit files; defaults to tracked project scripts')
    args = parser.parse_args()
    if args.paths:
        paths = [Path(name).resolve() for name in args.paths]
    else:
        tracked = subprocess.check_output(['git', 'ls-files', '-z', '--', '*.py', '*.sh', '*.zsh'], cwd=ROOT)
        paths = [ROOT / name.decode() for name in tracked.split(b'\0') if name]
    failed = False
    for path in paths:
        try:
            if path.suffix == '.py':
                ast.parse(path.read_bytes(), filename=str(path))
            else:
                words = shlex.split(path.read_text().splitlines()[0].removeprefix('#!'))
                shell = Path(words[1] if Path(words[0]).name == 'env' else words[0]).name
                if shell not in ('bash', 'zsh', 'sh'):
                    raise ValueError(f'Unsupported shell: {shell}')
                subprocess.run([shell, '-n', str(path)], check=True)
        except (OSError, ValueError, SyntaxError, IndexError, subprocess.CalledProcessError) as error:
            print(f'{path}: {error}', file=sys.stderr)
            failed = True
    print(f'Script syntax checks: {len(paths)} files; {"FAILED" if failed else "passed"}')
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
