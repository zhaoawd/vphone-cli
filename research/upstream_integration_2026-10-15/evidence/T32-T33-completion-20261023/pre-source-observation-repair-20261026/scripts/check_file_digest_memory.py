#!/usr/bin/env python3
"""Check production file-digest memory and output in an isolated macOS process."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD_BYTES = 512 * 1024 * 1024
MAX_RSS_BYTES = 64 * 1024 * 1024
HARNESS = r'''
import Darwin
import Foundation
let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
let result = try VPhoneFileDigest.sha256(input)
try input.close()
var usage = rusage()
guard getrusage(RUSAGE_SELF, &usage) == 0 else { fatalError("getrusage failed") }
let record: [String: Any] = ["sha256": result.digest, "bytes": result.size, "peak_rss": usage.ru_maxrss]
print(String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
'''


def main():
    with tempfile.TemporaryDirectory(prefix="vphone-digest-memory-") as tmp:
        work = Path(tmp)
        payload = work / "payload.bin"
        with payload.open("wb") as stream:
            stream.truncate(PAYLOAD_BYTES)
        main_swift = work / "main.swift"
        main_swift.write_text(HARNESS)
        binary = work / "digest"
        subprocess.run(["swiftc", "-swift-version", "6", "-O",
                        str(ROOT / "sources/VPhoneCore/VPhoneFileDigest.swift"),
                        str(main_swift), "-o", str(binary)], check=True, timeout=120)
        expected = hashlib.sha256()
        chunk = bytes(1024 * 1024)
        for _ in range(PAYLOAD_BYTES // len(chunk)):
            expected.update(chunk)
        result = subprocess.run([str(binary), str(payload)], check=True,
                                capture_output=True, text=True, timeout=60)
        record = json.loads(result.stdout)
        print(json.dumps(record, sort_keys=True), flush=True)
        if (record["sha256"] != expected.hexdigest() or record["bytes"] != PAYLOAD_BYTES
                or record["peak_rss"] > MAX_RSS_BYTES):
            raise SystemExit("File digest memory/output regression")


if __name__ == "__main__":
    main()
