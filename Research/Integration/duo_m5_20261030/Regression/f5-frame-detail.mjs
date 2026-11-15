// Inspect decoded full-size RGB differences inside the longest repeated luma observation.
// Pixel changes in a lossy movie do not prove that the source display updated.
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';

export function compareRGBA(previous, current) {
    if (current.length === 0 || current.length % 4 || previous.length !== current.length) throw Error('Invalid RGBA frames');
    let sum = 0, maximum = 0;
    const pixels = current.length / 4, changed = {0: 0, 2: 0, 8: 0, 16: 0};
    for (let p = 0; p < current.length; p += 4) {
        let largest = 0;
        for (let channel = 0; channel < 3; channel++) {
            const difference = Math.abs(current[p + channel] - previous[p + channel]);
            sum += difference; largest = Math.max(largest, difference);
        }
        maximum = Math.max(maximum, largest);
        for (const threshold of [0, 2, 8, 16]) if (largest > threshold) changed[threshold]++;
    }
    return {meanAbsoluteRGB: sum / (pixels * 3), maximumChannelDifference: maximum,
        pixelFractionAbove: Object.fromEntries(Object.entries(changed).map(([threshold, count]) => [threshold, count / pixels]))};
}

export async function inspect(movie, timing) {
    const repeat = timing.repeats.filter(row => !row.dark).sort((a, b) => b.spanMs - a.spanMs)[0];
    if (!repeat) throw Error('No repeated nonblack luma window');
    const indices = timing.samples.flatMap((frame, index) => frame.pts >= repeat.start && frame.pts <= repeat.end ? [index] : []);
    if (indices.length !== repeat.images || indices.length < 2) throw Error('Repeat/frame mismatch');
    const size = timing.width * timing.height * 4;
    if (!Number.isSafeInteger(size) || size <= 0 || size > 128 * 1024 * 1024) throw Error('Invalid frame size');
    const child = spawn('ffmpeg', ['-v', 'error', '-i', movie, '-map', '0:v:0', '-vf',
        `select='between(n,${indices[0]},${indices.at(-1)})',format=rgba`,
        '-fps_mode', 'passthrough', '-f', 'rawvideo', '-'], {stdio: ['ignore', 'pipe', 'pipe']});
    let stderr = '';
    child.stderr.on('data', chunk => { stderr += chunk; });
    const completed = new Promise((resolve, reject) => {
        child.on('error', reject);
        child.on('close', code => code === 0 ? resolve() : reject(Error('ffmpeg: ' + stderr)));
    });
    let pending = Buffer.alloc(0), previous, index = 0;
    const frames = [];
    for await (const chunk of child.stdout) {
        pending = Buffer.concat([pending, chunk]);
        while (pending.length >= size) {
            const frame = Buffer.from(pending.subarray(0, size));
            pending = pending.subarray(size);
            const originalIndex = indices[index++];
            if (originalIndex === undefined) throw Error('Too many decoded frames');
            frames.push({index: originalIndex, pts: timing.samples[originalIndex].pts,
                sha256: createHash('sha256').update(frame).digest('hex'),
                changeFromPrevious: previous ? compareRGBA(previous, frame) : null});
            previous = frame;
        }
    }
    await completed;
    if (pending.length || frames.length !== indices.length) throw Error('Incomplete decoded frames');
    return {scope: 'Decoded movie pixels only; source motion and codec differences are not distinguished',
        repeat, width: timing.width, height: timing.height, fullRGBAUnique: new Set(frames.map(row => row.sha256)).size, frames};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const [movie, timing] = process.argv.slice(2);
    if (!timing) throw Error('Usage: f5-frame-detail.mjs <movie> <movie-timing.json>');
    console.log(JSON.stringify(await inspect(movie, JSON.parse(fs.readFileSync(timing, 'utf8'))), null, 2));
}
