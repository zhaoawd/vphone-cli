import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, open, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import path from 'node:path';

const exec = promisify(execFile);
const [cliArg, sourceArg, outputArg] = process.argv.slice(2);
assert(cliArg && sourceArg && outputArg, 'usage: framebuffer-cache.mjs <cli> <pristine-cache> <new-output>');
const cli = path.resolve(cliArg), source = path.resolve(sourceArg), output = path.resolve(outputArg);
assert(!output.startsWith(source + path.sep) && output !== source);
await mkdir(output);
const cache = path.join(output, 'cache');
await exec('/bin/cp', ['-cR', source, cache]);
const identifier = 'dyld-cfw-quartzcore_unrotated_framebuffer';
const undo = path.join(cache, '.vphone-dsc-undo.json');
const report = { identifier, source, cache, phases: {} };

async function hash(file) {
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(file)) digest.update(chunk);
  return digest.digest('hex');
}
async function hashes(directory, includeUndo = true) {
  const names = (await readdir(directory)).filter(name =>
    name.startsWith('dyld_shared_cache_arm64e') || (includeUndo && name.startsWith('.vphone-dsc-undo.'))).sort();
  const result = {};
  let cursor = 0;
  await Promise.all(Array.from({ length: 4 }, async () => {
    while (cursor < names.length) {
      const name = names[cursor++];
      assert((await stat(path.join(directory, name))).isFile());
      result[name] = await hash(path.join(directory, name));
    }
  }));
  return Object.fromEntries(names.map(name => [name, result[name]]));
}
async function run(name, args) {
  const result = await exec(cli, ['cfw', ...args], { maxBuffer: 4 * 1024 * 1024 });
  await writeFile(path.join(output, name + '.log'), result.stdout + result.stderr);
  return result.stdout;
}
async function wordGroups(directory) {
  const data = await readFile(path.join(directory, '.vphone-dsc-undo.words'));
  assert.equal(data.subarray(0, 8).toString(), 'VPDSCUW1');
  let cursor = 8;
  const count = data.readUInt32LE(cursor); cursor += 4;
  const groups = new Map();
  for (let index = 0; index < count; index++) {
    const length = data.readUInt16LE(cursor); cursor += 2;
    const id = data.subarray(cursor, cursor + length).toString(); cursor += length;
    const words = Number(data.readBigUInt64LE(cursor)); cursor += 8;
    assert(Number.isSafeInteger(words) && words >= 0 && cursor + 12 * words <= data.length);
    assert(!groups.has(id));
    groups.set(id, { data, count: words, addresses: cursor, originals: cursor + 8 * words });
    cursor += 12 * words;
  }
  assert.equal(cursor, data.length);
  return groups;
}
// Revert normalizes legacy X1 page runs into the word store. Check every
// retained original and every migrated word, independently of JSON placement.
async function verifyPreviousOwners(beforeJSON, afterJSON) {
  const beforeGroups = await wordGroups(source), afterGroups = await wordGroups(cache);
  const migrated = new Map(), kept = [];
  const x1 = new Set(['dyld-boot-arm64e_x1_bootstrap', 'dyld-cfw-arm64e_x1_cache']);
  for (const record of beforeJSON.Records) {
    const bytes = Buffer.from(record.Original, 'base64');
    if (!x1.has(record.PatchID) || record.VMA % 4 || bytes.length % 4) { kept.push(record); continue; }
    const file = await open(path.join(source, record.Chunk), 'r');
    const live = Buffer.alloc(bytes.length);
    try { assert.equal((await file.read(live, 0, live.length, record.FileOffset)).bytesRead, live.length); }
    finally { await file.close(); }
    const entries = migrated.get(record.PatchID) ?? new Map();
    for (let offset = 0; offset < bytes.length; offset += 4) {
      if (live.readUInt32LE(offset) !== bytes.readUInt32LE(offset)) {
        entries.set(BigInt(record.VMA + offset), bytes.readUInt32LE(offset));
      }
    }
    migrated.set(record.PatchID, entries);
  }
  assert.deepEqual(afterJSON, { ...beforeJSON, Records: kept }, 'unrelated byte-run owners changed');
  assert.deepEqual([...afterGroups.keys()].sort(), [...new Set([...beforeGroups.keys(), ...migrated.keys()])].sort());
  let migratedWords = 0;
  for (const [id, current] of afterGroups) {
    const previous = beforeGroups.get(id);
    const extra = [...(migrated.get(id) ?? new Map()).entries()].sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0);
    if (!extra.length) {
      assert(previous);
      assert.equal(current.count, previous.count);
      assert(current.data.subarray(current.addresses, current.originals + current.count * 4)
        .equals(previous.data.subarray(previous.addresses, previous.originals + previous.count * 4)), id);
      continue;
    }
    let oldIndex = 0, extraIndex = 0, actualIndex = 0;
    while (oldIndex < (previous?.count ?? 0) || extraIndex < extra.length) {
      const oldAddress = oldIndex < (previous?.count ?? 0) ? previous.data.readBigUInt64LE(previous.addresses + oldIndex * 8) : null;
      const next = extra[extraIndex];
      const takeOld = oldAddress !== null && (!next || oldAddress <= next[0]);
      const address = takeOld ? oldAddress : next[0];
      const original = takeOld ? previous.data.readUInt32LE(previous.originals + oldIndex * 4) : next[1];
      assert(actualIndex < current.count, `${id}: missing original`);
      assert.equal(current.data.readBigUInt64LE(current.addresses + actualIndex * 8), address, id);
      assert.equal(current.data.readUInt32LE(current.originals + actualIndex * 4), original, id);
      if (takeOld) oldIndex++;
      if (next && address === next[0]) { extraIndex++; migratedWords++; }
      actualIndex++;
    }
    assert.equal(actualIndex, current.count, `${id}: unexpected originals`);
  }
  return migratedWords;
}
const before = await hashes(source);
assert.deepEqual(await hashes(cache), before);
const originalUndo = JSON.parse(await readFile(undo, 'utf8'));
const dry = await run('dry-run', ['patch-quartzcore-unrotated-framebuffer', cache, '--dry-run']);
assert.match(dry, /already patched: false/);
assert.deepEqual(await hashes(cache), before, 'dry run changed cache or existing undo');
report.phases.dryRun = { unchanged: true, output: dry.trim() };

const args = ['patch-quartzcore-unrotated-framebuffer', cache, '--undo-log', undo, '--undo-id', identifier];
const applied = await run('apply', args);
assert.match(applied, /already patched: false/);
const after = await hashes(cache);
const changedChunks = Object.keys(before).filter(name => name.startsWith('dyld_shared_cache_') && before[name] !== after[name]);
assert.equal(changedChunks.length, 1, 'one QuartzCore chunk must change');
const newUndo = JSON.parse(await readFile(undo, 'utf8'));
assert(newUndo.Records.some(record => record.PatchID === identifier));
await exec('/bin/cp', ['-cR', cache, path.join(output, 'cache-applied')]);
report.phases.apply = { changedChunks, output: applied.trim() };

const repeated = await run('repeat', args);
assert.match(repeated, /already patched: true/);
assert.deepEqual(await hashes(cache), after, 'repeat changed cache or undo ownership');
report.phases.repeat = { unchanged: true };
await run('revert', ['patch-dsc-revert', cache, '--undo-log', undo, '--patch', identifier]);
assert.deepEqual(await hashes(cache, false), Object.fromEntries(Object.entries(before).filter(([name]) => name.startsWith('dyld_shared_cache_'))),
  'reverting the new patch changed an existing patch or signature');
const revertedUndo = JSON.parse(await readFile(undo, 'utf8'));
const migratedWords = await verifyPreviousOwners(originalUndo, revertedUndo);
assert.deepEqual(await hashes(source), before, 'source fixture changed');
report.phases.revert = { cacheExactMatch: true, previousOwnersPreserved: true, migratedWords, sourceUnchanged: true };
report.beforeSHA256 = before;
report.appliedSHA256 = after;
await writeFile(path.join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({ dryRun: true, changedChunks, repeat: true, exactRevert: true, previousOwnersPreserved: true, output }));
