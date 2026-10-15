"""Exercise rejection of damaged measurement evidence using the fresh smoke data."""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('controller', E / 'run-benchmarks.py')
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)


class MeasurementChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.row = json.loads((E / 'smoke-observations.jsonl').read_text().splitlines()[0])
        cls.log = (E / (cls.row['label'] + '.log')).read_text()
        cls.variant = json.loads((E / 'variants.json').read_text())['variants'][0]
        cls.trace = Path(cls.row['detail']['trace']).read_text()

    def testValidCaptureEvidence(self):
        sample = controller.parse_sample(self.log, self.row['label'], 'capture', self.row['sample']['bytes'])
        controller.trace_details(Path(self.row['detail']['trace']), sample, self.variant)

    def testMismatchedClockIsRejected(self):
        prefix = 'kernel-io-benchmark '
        lines = self.log.splitlines()
        for index, line in enumerate(lines):
            if line.startswith(prefix):
                value = json.loads(line[len(prefix):])
                if value['event'] == 'measurement-end':
                    value['elapsed_ns'] += 1
                    lines[index] = prefix + json.dumps(value)
        with self.assertRaises(RuntimeError):
            controller.parse_sample('\n'.join(lines), self.row['label'], 'capture', self.row['sample']['bytes'])

    def testWrongFactorIsRejected(self):
        variant = copy.deepcopy(self.variant); variant['third'] = True
        with self.assertRaises(RuntimeError):
            controller.trace_details(Path(self.row['detail']['trace']), self.row['sample'], variant)

    def checkCorruptTrace(self, mutate):
        rows = [json.loads(line) for line in self.trace.splitlines()]
        mutate(rows)
        with tempfile.TemporaryDirectory(prefix='kernel-io-measurement-check-') as directory:
            path = Path(directory) / 'trace.jsonl'
            path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
            with self.assertRaises((RuntimeError, ValueError)):
                controller.trace_details(path, self.row['sample'], self.variant)

    def testIncompleteFooterIsRejected(self):
        self.checkCorruptTrace(lambda rows: rows[-1].update(complete=False))

    def testMissingSHAByteIsRejected(self):
        def mutate(rows):
            for row in rows:
                if row.get('phase') == 'generation.fileSHA256':
                    row['counts']['bytes'] -= 1
                    return
            self.fail('No SHA span')
        self.checkCorruptTrace(mutate)


if __name__ == '__main__':
    unittest.main(verbosity=2)
