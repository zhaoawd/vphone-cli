// Read movie timestamps and downscaled luma samples without resampling to a
// constant frame rate. Report repeated observations separately from gaps.
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const [movie] = process.argv.slice(2);
if (!movie) throw Error('Usage: f5-mov-timing.mjs <recording.mov>');
function run(tool, args) {
    const result = spawnSync(tool, args, { maxBuffer: 64 * 1024 * 1024 });
    if (result.status !== 0) throw Error(`${tool}: ${result.error ?? result.stderr.toString()}`);
    return result.stdout;
}
const probe = JSON.parse(run('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries',
    'frame=pts_time:stream=width,height', '-of', 'json', movie]));
const times = probe.frames.map(frame => Number(frame.pts_time));
const pixels = run('ffmpeg', ['-v', 'error', '-i', movie, '-map', '0:v:0', '-vf', 'scale=64:64:flags=area,format=gray',
    '-fps_mode', 'passthrough', '-f', 'rawvideo', '-']);
const size = 64 * 64;
if (times.length < 2 || times.some((t, i) => !Number.isFinite(t) || (i > 0 && t <= times[i - 1])) || pixels.length !== times.length * size) {
    throw Error('Expected strictly increasing PTS and one decoded image per video frame');
}
const frames = times.map((pts, i) => {
    const luma = pixels.subarray(i * size, (i + 1) * size);
    return { pts, dark: luma.every(v => v <= 16), hash: createHash('sha256').update(luma).digest('hex') };
});
const intervals = times.slice(1).map((end, i) => ({ start: times[i], end, ms: (end - times[i]) * 1000 }));
const sorted = intervals.map(row => row.ms).sort((a, b) => a - b);
const repeats = [];
for (let start = 0; start < frames.length;) {
    let end = start + 1;
    while (end < frames.length && frames[end].hash === frames[start].hash) end++;
    if (end - start > 1) {
        const window = intervals.slice(start, end - 1);
        repeats.push({ start: times[start], end: times[end - 1], images: end - start, dark: frames[start].dark,
            spanMs: (times[end - 1] - times[start]) * 1000, maxIntervalMs: Math.max(...window.map(row => row.ms)) });
    }
    start = end;
}
console.log(JSON.stringify({
    width: probe.streams[0].width, height: probe.streams[0].height, frames: times.length,
    ptsSpan: times.at(-1) - times[0], minIntervalMs: sorted[0], medianIntervalMs: sorted[Math.floor(sorted.length / 2)],
    maxIntervalMs: sorted.at(-1), gapsOver100Ms: intervals.filter(row => row.ms > 100),
    darkSamples: frames.filter(frame => frame.dark).length, repeats, samples: frames,
}, null, 2));
