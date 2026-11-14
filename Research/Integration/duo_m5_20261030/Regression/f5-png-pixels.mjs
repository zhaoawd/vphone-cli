// Check every decoded pixel, including alpha; no scaling or JPEG conversion.
import { spawnSync } from 'node:child_process';

const files = process.argv.slice(2);
if (!files.length || files.some(file => !file.endsWith('.png'))) throw Error('Usage: f5-png-pixels.mjs <capture.png> ...');
const results = files.map(file => {
    const decoded = spawnSync('ffmpeg', ['-v', 'error', '-threads', '1', '-i', file, '-frames:v', '1',
        '-pix_fmt', 'rgba', '-f', 'rawvideo', '-'], { maxBuffer: 64 * 1024 * 1024 });
    if (decoded.status !== 0 || !decoded.stdout.length || decoded.stdout.length % 4) {
        throw Error(`${file}: ${decoded.error ?? decoded.stderr.toString()}`);
    }
    let minAlpha = 255, maxAlpha = 0, maxRGB = 0;
    for (let i = 0; i < decoded.stdout.length; i += 4) {
        maxRGB = Math.max(maxRGB, decoded.stdout[i], decoded.stdout[i + 1], decoded.stdout[i + 2]);
        minAlpha = Math.min(minAlpha, decoded.stdout[i + 3]);
        maxAlpha = Math.max(maxAlpha, decoded.stdout[i + 3]);
    }
    return { file, pixels: decoded.stdout.length / 4, minAlpha, maxAlpha, maxRGB };
});
console.log(JSON.stringify(results, null, 2));
