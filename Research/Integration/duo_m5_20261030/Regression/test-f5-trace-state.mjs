import assert from 'node:assert/strict';
import { test } from 'node:test';
import { originalSHA256, candidateSHA256, validateTraceBaseline, validateTraceBundle } from './f5-trace-state.mjs';

const baseline = { originalSHA256, candidateSHA256, rootReadOnly: true };
test('admits the approved original and diagnostic library pair', () => {
    assert.doesNotThrow(() => validateTraceBaseline(baseline));
    assert.doesNotThrow(() => validateTraceBundle(originalSHA256));
});
test('rejects the observed auto-synced diagnostic library as an original backup', () => {
    assert.throws(() => validateTraceBaseline({ ...baseline, originalSHA256: candidateSHA256, rootReadOnly: false }), /original/);
});
test('requires the approved read-only baseline and diagnostic bytes', () => {
    assert.throws(() => validateTraceBaseline({ ...baseline, rootReadOnly: false }), /read-only/);
    assert.throws(() => validateTraceBaseline({ ...baseline, candidateSHA256: '0'.repeat(64) }), /diagnostic/);
});
test('blocks a Bundle that would auto-install the diagnostic before backup', () => {
    assert.throws(() => validateTraceBundle(candidateSHA256), /auto-sync/);
});
