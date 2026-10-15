#!/usr/bin/env python3
"""Verify exported source metadata and the pure Swift helper's repaired IMG4."""
import hashlib
import importlib.util
import json
from pathlib import Path

import pyimg4

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("container_compare", HERE.parent / "container-format/compare-containers.py")
der = importlib.util.module_from_spec(spec)
spec.loader.exec_module(der)
reference = json.loads((HERE.parent / "committed-readback-v7.json").read_text())
comparison = json.loads((HERE.parent / "container-format/comparison.json").read_text())
source_path = Path("/private/tmp/task8-pristine-kernel.im4p")
source = der.read_regular(source_path)
assert der.sha(source) == reference["proof"]["inputSHA256"]
fields = der.children(source, der.tlv(source))
description = der.value(source, fields[2]).decode("ascii")
properties = [der.describe(source, node) for node in fields[4:] if node["tag"] == "a0"]
baseline_properties = comparison["baseline"]["extra_im4p_children"]
assert description == comparison["baseline"]["description"]
assert [(p["type_name"], p["sha256"]) for p in properties] == [(p["type_name"], p["sha256"]) for p in baseline_properties]
original = pyimg4.IM4P(source)
compression = original.payload.compression.name
original.payload.decompress()
baseline_path = Path("/private/tmp/task8-container-baseline.img4")
output_path = Path("/private/tmp/task8-container-repaired-v8.img4")
baseline, repaired = der.read_regular(baseline_path), der.read_regular(output_path)
assert der.sha(baseline) == reference["kernels"]["baseline"]["image_sha256"]
assert repaired == baseline
decoded = pyimg4.IMG4(repaired).im4p.payload
assert decoded.compression == pyimg4.Compression.NONE
assert der.sha(decoded.data) == reference["proof"]["payloadSHA256"]
result = {
    "scope": "Pure exported-file verification; no VM, mount or AMFI operation.",
    "source": {"export": str(source_path), "sha256": der.sha(source), "bytes": len(source),
               "proof_input_sha_matches": True, "description": description, "compression": compression,
               "decoded_bytes": len(original.payload.data), "decoded_sha256": der.sha(original.payload.data),
               "payp": properties, "description_matches_baseline": True, "payp_matches_baseline": True},
    "repaired": {"path": str(output_path), "sha256": der.sha(repaired), "bytes": len(repaired),
                 "exact_baseline_bytes": True, "decoded_sha256": der.sha(decoded.data)},
    "generation_id": reference["receipt"]["generationID"],
    "source_origin_reported_by_exporter": "originals/iPhone17,3_26.1_23B85_Restore/kernelcache.research.vphone600",
    "passed": True,
    "limitation": "Exact file reconstruction does not establish VM boot success or the cause of the earlier boot failure."
}
(HERE / "repacked-verification.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({"source_sha256": der.sha(source), "repaired_sha256": der.sha(repaired), "exact_baseline_bytes": True}))
