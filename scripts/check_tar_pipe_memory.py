#!/usr/bin/env python3
"""Check bounded memory in the real macOS archive relay, in isolated processes."""

import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD_BYTES = 1024 * 1024 * 1024
MAX_RSS_BYTES = 128 * 1024 * 1024
HARNESS = r'''
import Darwin
import Foundation
let input = CommandLine.arguments[1]
let mode = CommandLine.arguments[2]
var count: Int64 = 0
var monotonic = true
let error = try VPhoneProcessRunner.runCountingTarPipe(
    producerArgs: mode == "producer" ? ["--format", "gnutar", "-cf", "-", "@" + input] : nil,
    sourceFile: mode == "file" ? URL(fileURLWithPath: input) : nil,
    consumerArgs: ["-tf", "-"],
    onBytes: { next in monotonic = monotonic && next > count; count = next })
var usage = rusage()
guard getrusage(RUSAGE_SELF, &usage) == 0 else { fatalError("getrusage failed") }
let record: [String: Any] = ["mode": mode, "bytes": count, "peak_rss": usage.ru_maxrss,
                           "monotonic": monotonic, "error": error ?? ""]
let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
'''


def main():
    with tempfile.TemporaryDirectory(prefix="vphone-tar-memory-") as tmp:
        work = Path(tmp)
        archive = work / "input.tar"
        entry = tarfile.TarInfo("payload.bin")
        entry.size = PAYLOAD_BYTES
        # A valid uncompressed tar with a zero payload; no 1 GiB allocation.
        with archive.open("wb") as stream:
            stream.write(entry.tobuf(format=tarfile.USTAR_FORMAT))
            stream.truncate(512 + PAYLOAD_BYTES + 1024)
        main_swift = work / "main.swift"
        main_swift.write_text(HARNESS)
        binary = work / "relay"
        # VPhoneProcessRunner registers its children with vm create's
        # cancellation controller, which needs the process table and the
        # shutdown grace; nothing else from VPhoneCore is compiled in.
        sources = ["VPhoneProcessRunner.swift", "VPhoneChildCancellation.swift",
                   "VPhoneProcessIdentity.swift", "VPhoneShutdownPolicy.swift"]
        subprocess.run([
            "swiftc", "-swift-version", "6", "-O",
            *(str(ROOT / "sources/VPhoneCore" / name) for name in sources),
            str(main_swift), "-o", str(binary),
        ], check=True, timeout=120)
        failures = []
        for mode in ("file", "producer"):
            result = subprocess.run(
                [str(binary), str(archive), mode], check=True,
                capture_output=True, text=True, timeout=90,
            )
            record = json.loads(result.stdout)
            print(json.dumps(record, sort_keys=True), flush=True)
            if (record["error"] or not record["monotonic"]
                    or record["bytes"] < PAYLOAD_BYTES + 1024
                    or record["peak_rss"] > MAX_RSS_BYTES):
                failures.append(mode)
        if failures:
            raise SystemExit("Archive relay memory/count regression: " + ", ".join(failures))


if __name__ == "__main__":
    main()
