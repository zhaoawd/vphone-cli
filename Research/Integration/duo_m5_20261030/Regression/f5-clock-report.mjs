// Classify the captured JPEGs without assigning synthetic frame timestamps.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const root = process.argv[2];
if (!root) throw Error('Usage: f5-clock-report.mjs <f5-clock output>');
const read = (dir, name) => JSON.parse(fs.readFileSync(path.join(dir, name)));
const dual = process.argv.includes('--dual');
console.log(dual
    ? 'trial\tsource\tpanel\tdisplay_id\tstate\tsent_ms\treceived_ms\trequest_ms\treason'
    : 'trial\tinitial_degrees\tfinal_degrees\tsampled_degrees\tblack_samples\tfirst_black_lower_ms\tlast_black_upper_ms\tmax_gap_ms\tmax_identical_ms\tmax_request_ms');
const pixelCount = 64 * 64;
const isDark = luma => luma.every(v => v <= 16);
function printSample(name, source, panel, id, state, sample, action, reason = '') {
    console.log([name, source, panel, id, state, Math.round(sample.sent - action.sent),
        Math.round(sample.received - action.sent), Math.round(sample.received - sample.sent), reason].join('\t'));
}
for (const name of fs.readdirSync(root).filter(x => /^\d+-\d+-(open|closed)$/.test(x)).sort()) {
    const dir = path.join(root, name);
    const actionFile = path.join(dir, 'action.json');
    if (!fs.existsSync(actionFile)) continue;
    const { before, action, after } = read(dir, 'action.json');
    const frames = read(dir, 'samples.json').filter(s => s.frame !== undefined);
    if (!frames.length || !action.response.ok) throw Error(`Invalid trial: ${name}`);
    const decoded = spawnSync('ffmpeg', ['-v', 'error', '-threads', '1', '-f', 'mjpeg',
        '-i', path.join(dir, 'frames.mjpeg'), '-vf', 'scale=64:64:flags=area,format=gray',
        '-f', 'rawvideo', '-'], { maxBuffer: 2 * 1024 * 1024 });
    const pixels = pixelCount;
    if (decoded.status !== 0 || decoded.stdout.length !== frames.length * pixels) {
        throw Error(`Decoded frame count mismatch: ${name}`);
    }
    if (dual) {
        for (const [i, frame] of frames.entries()) {
            printSample(name, 'host', 'presentation', '-', isDark(decoded.stdout.subarray(i * pixels, (i + 1) * pixels)) ? 'dark' : 'visible', frame, action);
        }
        for (const sample of read(dir, 'guest-samples.json')) {
            const source = sample.metadata?.source;
            let state = 'unavailable';
            if (sample.file) {
                if (!/^guest-\d+\.(png|jpg)$/.test(sample.file)) throw Error('Unexpected capture filename');
                const image = spawnSync('ffmpeg', ['-v', 'error', '-threads', '1', '-i', path.join(dir, sample.file),
                    '-vf', 'scale=64:64:flags=area,format=gray', '-frames:v', '1', '-f', 'rawvideo', '-']);
                if (image.status !== 0 || image.stdout.length !== pixels) throw Error(`Invalid guest image: ${name}/${sample.file}`);
                state = isDark(image.stdout) ? 'dark' : 'visible';
            }
            printSample(name, 'guest', source?.name ?? 'unknown', source?.display_id ?? '-', state, sample, action,
                sample.metadata?.reason ?? sample.error ?? '');
        }
        continue;
    }
    const dark = [];
    let previous, identicalStart, maxIdentical = 0, maxGap = 0, maxRequest = 0;
    for (const [i, frame] of frames.entries()) {
        const luma = decoded.stdout.subarray(i * pixels, (i + 1) * pixels);
        const hash = createHash('sha256').update(luma).digest('hex');
        maxRequest = Math.max(maxRequest, frame.received - frame.sent);
        if (i) maxGap = Math.max(maxGap, frame.received - frames[i - 1].received);
        if (frame.received < action.sent) continue;
        if (isDark(luma)) dark.push(frame);
        if (hash !== previous) identicalStart = frame.received;
        maxIdentical = Math.max(maxIdentical, frame.received - identicalStart);
        previous = hash;
    }
    // Sample intervals include RPC/encoding overhead; they bound sample time,
    // not the full duration of a black transition. A static Home Screen can
    // also produce identical frames, so that column does not establish a stall.
    const ms = n => Math.round(n);
    const degrees = [...new Set(frames.map(f => f.state?.degrees ?? 'unknown'))].join(',');
    console.log([name, before.degrees, after.degrees, degrees, dark.length,
        dark.length ? ms(dark[0].sent - action.sent) : '-',
        dark.length ? ms(dark.at(-1).received - action.sent) : '-',
        ms(maxGap), ms(maxIdentical), ms(maxRequest)].join('\t'));
}
