// Classify the captured JPEGs without assigning synthetic frame timestamps.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const [root, mode] = process.argv.slice(2);
if (!root || (mode && !['--dual', '--timing'].includes(mode))) {
    throw Error('Usage: f5-clock-report.mjs <f5-clock output> [--dual|--timing]');
}
const read = (dir, name) => JSON.parse(fs.readFileSync(path.join(dir, name)));
const dual = mode === '--dual';
const timing = mode === '--timing';
console.log(dual
    ? 'trial\tsource\tpanel\tdisplay_id\tstate\tsent_ms\treceived_ms\trequest_ms\treason\tluma_sha256\tsample_file'
    : timing
        ? 'trial\tpost_action_images\tmissing_images\tmax_request_ms\tmax_between_requests_ms\tmax_same_lower_ms\tmax_same_upper_ms\tmax_same_images'
        : 'trial\tinitial_degrees\tfinal_degrees\tsampled_degrees\tblack_samples\tfirst_black_lower_ms\tlast_black_upper_ms\tmax_gap_ms\tmax_identical_ms\tmax_request_ms');
const pixelCount = 64 * 64;
const isDark = luma => luma.every(v => v <= 16);
function printSample(name, source, panel, id, state, sample, action, reason = '', hash = '') {
    console.log([name, source, panel, id, state, Math.round(sample.sent - action.sent),
        Math.round(sample.received - action.sent), Math.round(sample.received - sample.sent), reason,
        hash, sample.file ?? (sample.frame !== undefined ? `frame:${sample.frame}` : '')].join('\t'));
}
for (const name of fs.readdirSync(root).filter(x => /^\d+-\d+-(open|closed)$/.test(x)).sort()) {
    const dir = path.join(root, name);
    const actionFile = path.join(dir, 'action.json');
    if (!fs.existsSync(actionFile)) continue;
    const { before, action, after } = read(dir, 'action.json');
    const samples = read(dir, 'samples.json');
    const frames = samples.filter(s => s.frame !== undefined);
    if (!frames.length || !action.response.ok) throw Error(`Invalid trial: ${name}`);
    const decoded = spawnSync('ffmpeg', ['-v', 'error', '-threads', '1', '-f', 'mjpeg',
        '-i', path.join(dir, 'frames.mjpeg'), '-vf', 'scale=64:64:flags=area,format=gray',
        '-f', 'rawvideo', '-'], { maxBuffer: 2 * 1024 * 1024 });
    const pixels = pixelCount;
    if (decoded.status !== 0 || decoded.stdout.length !== frames.length * pixels) {
        throw Error(`Decoded frame count mismatch: ${name}`);
    }
    if (timing) {
        let imageIndex = 0, count = 0, missing = 0, request = 0, gap = 0;
        let previous, start, hash, run = 0;
        let longest = { lower: 0, upper: 0, images: 0 };
        for (const sample of samples) {
            const hasImage = sample.frame !== undefined;
            const index = hasImage ? imageIndex++ : -1;
            if (sample.sent < action.sent) continue;
            request = Math.max(request, sample.received - sample.sent);
            if (previous) gap = Math.max(gap, sample.sent - previous.received);
            previous = sample;
            if (!hasImage) {
                missing++;
                hash = undefined;
                run = 0;
                continue;
            }
            count++;
            const luma = decoded.stdout.subarray(index * pixels, (index + 1) * pixels);
            const next = createHash('sha256').update(luma).digest('hex');
            if (next !== hash) {
                start = sample;
                run = 0;
            }
            hash = next;
            if (++run < 2) continue;
            // The images were sampled somewhere inside their request windows.
            // This bounds separation of the observations, not a freeze: the
            // output can change between them or be static independently.
            const lower = Math.max(0, sample.sent - start.received);
            const upper = sample.received - start.sent;
            if (lower > longest.lower || (lower === longest.lower && upper > longest.upper)) {
                longest = { lower, upper, images: run };
            }
        }
        console.log([name, count, missing, request, gap, longest.lower, longest.upper, longest.images]
            .map(value => typeof value === 'number' ? Math.round(value) : value).join('\t'));
        continue;
    }
    if (dual) {
        for (const [i, frame] of frames.entries()) {
            const luma = decoded.stdout.subarray(i * pixels, (i + 1) * pixels);
            printSample(name, 'host', 'presentation', '-', isDark(luma) ? 'dark' : 'visible', frame, action, '',
                createHash('sha256').update(luma).digest('hex'));
        }
        for (const sample of read(dir, 'guest-samples.json')) {
            const source = sample.metadata?.source;
            let state = 'unavailable';
            let hash = '';
            if (sample.file) {
                if (!/^guest-\d+\.(png|jpg)$/.test(sample.file)) throw Error('Unexpected capture filename');
                const image = spawnSync('ffmpeg', ['-v', 'error', '-threads', '1', '-i', path.join(dir, sample.file),
                    '-vf', 'scale=64:64:flags=area,format=gray', '-frames:v', '1', '-f', 'rawvideo', '-']);
                if (image.status !== 0 || image.stdout.length !== pixels) throw Error(`Invalid guest image: ${name}/${sample.file}`);
                state = isDark(image.stdout) ? 'dark' : 'visible';
                hash = createHash('sha256').update(image.stdout).digest('hex');
            }
            printSample(name, 'guest', source?.name ?? 'unknown', source?.display_id ?? '-', state, sample, action,
                sample.metadata?.reason ?? sample.error ?? '', hash);
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
