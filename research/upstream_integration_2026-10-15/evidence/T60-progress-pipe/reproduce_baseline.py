import subprocess
import tempfile
from pathlib import Path
import sys
sys.path.insert(0, str(Path.cwd()))
from tests.test_progress_pipe import ProgressPipeTests, ROOT
with tempfile.TemporaryDirectory(prefix='vphone-progress-baseline-') as temporary:
    work = Path(temporary)
    original = work / 'VPhoneProgressBar.swift'
    original.write_bytes(subprocess.check_output(['git', 'show', '2df4be8ceab956d498f2cc7d79b26f4ddbdee467:sources/vphone-cli/VPhoneProgressBar.swift']))
    binary = work / 'baseline'
    sources = [original, ROOT / 'tests/fixtures/progress_pipe/main.swift']
    sources += [ROOT / 'sources/VPhoneCore' / name for name in ('VPhoneProcessRunner.swift', 'VPhoneChildCancellation.swift', 'VPhoneProcessIdentity.swift', 'VPhoneShutdownPolicy.swift')]
    subprocess.run(['swiftc', '-swift-version', '6', '-module-cache-path', str(work / 'modules'), *map(str, sources), '-o', str(binary)], check=True)
    ProgressPipeTests.binary = binary
    ProgressPipeTests.work = work
    for mode in ('broken-ignored', 'broken-default', 'hangup', 'broken-tar'):
        try:
            ProgressPipeTests().run_transfer(mode)
        except AssertionError as error:
            print(f'RED {mode}: {error}')
        else:
            raise AssertionError(f'Expected baseline failure for {mode}')
