import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

export function classifyBoot(log, preflight = '') {
    const patterns = {
        hostStarted: /\[vphone\] VM started/, controlListening: /\[hostctl\] listening/,
        rpcConnected: /\[control\] connected to vphoned HTTP API/,
        driverKitWaiting: /DK:.*waiting for server/g, driverKitFailed: /DK:.*failed to find server/g,
        earlyBootComplete: /early boot complete/i,
        guestOff: /ApplePSCI - system off/, hostStopped: /\[vphone\] Guest stopped/,
        interrupt: /\[vphone\] SIGINT/, amfiRefused: /AMFI blocked vphone-vm/,
    };
    const events = Object.fromEntries(Object.entries(patterns).map(([name, pattern]) =>
        [name, name.startsWith('driverKit') ? [...log.matchAll(pattern)].length : pattern.test(name === 'amfiRefused' ? preflight : log)]));
    if (events.amfiRefused && events.hostStarted) throw Error('Preflight refusal and guest start need separate attempt records');
    const phase = events.amfiRefused ? 'host_preflight_refused'
        : events.rpcConnected ? 'rpc_connected'
        : events.hostStarted ? 'guest_rpc_unavailable' : 'insufficient_evidence';
    return {phase, events, cause: null,
        scope: 'Log observations; DriverKit errors alone do not establish the cause of an unavailable RPC'};
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const [log, preflight] = process.argv.slice(2);
    if (!log) throw Error('Usage: boot-evidence-report.mjs <boot.log> [same-attempt preflight.log]');
    console.log(JSON.stringify(classifyBoot(fs.readFileSync(log, 'utf8'), preflight ? fs.readFileSync(preflight, 'utf8') : ''), null, 2));
}
