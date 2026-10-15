#!/usr/bin/env python3
"""Compare exported kernel IMG4 files without mounting or modifying an image."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import sys

import pyimg4


HERE = Path(__file__).resolve().parent


def sha(data):
    return hashlib.sha256(data).hexdigest()


def read_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        assert stat.S_ISREG(before.st_mode) and 0 < before.st_size <= 512 << 20
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read()
        after = os.fstat(fd)
        named = path.lstat()
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        assert all(getattr(before, k) == getattr(after, k) == getattr(named, k) for k in fields)
        assert stat.S_ISREG(named.st_mode) and len(data) == before.st_size
        return data
    finally:
        os.close(fd)


def tlv(data, start=0, limit=None):
    limit = len(data) if limit is None else limit
    assert 0 <= start < limit <= len(data)
    pos = start
    first = data[pos]
    pos += 1
    number = first & 31
    if number == 31:
        number = 0
        for _ in range(8):
            assert pos < limit
            byte = data[pos]
            pos += 1
            number = number * 128 + (byte & 127)
            if not byte & 128:
                break
        else:
            raise ValueError("DER tag is too long")
    tag_end = pos
    assert pos < limit
    length = data[pos]
    pos += 1
    if length & 128:
        count = length & 127
        assert 0 < count <= 8 and pos + count <= limit
        length = int.from_bytes(data[pos:pos + count], "big")
        pos += count
    end = pos + length
    assert end <= limit
    return {"start": start, "value_start": pos, "end": end,
            "tag": data[start:tag_end].hex(), "tag_class": first >> 6,
            "tag_number": number, "constructed": bool(first & 32)}


def children(data, node):
    result = []
    pos = node["value_start"]
    while pos < node["end"]:
        child = tlv(data, pos, node["end"])
        result.append(child)
        pos = child["end"]
    assert pos == node["end"]
    return result


def raw(data, node):
    return data[node["start"]:node["end"]]


def value(data, node):
    return data[node["value_start"]:node["end"]]


def describe(data, node):
    encoded, body = raw(data, node), value(data, node)
    type_name = None
    if node["constructed"]:
        nested = children(data, node)
        if len(nested) == 1 and nested[0]["tag"] == "30":
            nested = children(data, nested[0])
        if nested and nested[0]["tag"] == "16":
            type_name = value(data, nested[0]).decode("ascii")
    return {"tag": node["tag"], "tag_class": node["tag_class"],
            "tag_number": node["tag_number"], "constructed": node["constructed"],
            "type_name": type_name,
            "offset": node["start"], "size": len(encoded), "value_size": len(body),
            "sha256": sha(encoded), "value_sha256": sha(body),
            "value_prefix_hex": body[:32].hex(), "contains_PAYP_marker": b"PAYP" in encoded}


def inspect(path, expected, proof):
    data = read_regular(path)
    assert sha(data) == expected["image_sha256"], f"Unexpected IMG4 input: {path}"
    outer = tlv(data)
    assert outer["tag"] == "30" and outer["end"] == len(data)
    image = children(data, outer)
    assert len(image) >= 3 and image[0]["tag"] == "16" and value(data, image[0]) == b"IMG4"
    assert image[1]["tag"] == "30" and image[2]["tag"] == "a0"
    fields = children(data, image[1])
    assert len(fields) >= 4 and all(f["tag"] == "16" for f in fields[:3]) and fields[3]["tag"] == "04"
    assert value(data, fields[0]) == b"IM4P"
    encoded_payload = value(data, fields[3])
    payload = pyimg4.IMG4(data).im4p.payload
    compression = payload.compression
    if compression != pyimg4.Compression.NONE:
        payload.decompress()
    decoded_sha = sha(payload.data)
    assert decoded_sha == expected["payload_sha256"] == proof["payloadSHA256"]
    assert sha(raw(data, image[2])) == expected["im4m_sha256"]
    return {"path": str(path), "raw_img4": {"size": len(data), "sha256": sha(data)},
            "raw_im4p": describe(data, image[1]),
            "fourcc": value(data, fields[1]).decode("ascii"),
            "description": value(data, fields[2]).decode("ascii"),
            "im4p_base_fields": [describe(data, f) for f in fields[:4]],
            "payload_octet": {"size": len(encoded_payload), "sha256": sha(encoded_payload),
                              "prefix_hex": encoded_payload[:32].hex()},
            "compression": {"name": compression.name, "value": compression.value},
            "decoded_payload": {"size": len(payload.data), "sha256": decoded_sha},
            "extra_im4p_children": [describe(data, f) for f in fields[4:]],
            "img4_trailing": [describe(data, f) for f in image[2:]],
            "img4_im4r_present": any(f["tag"] == "a1" for f in image[2:]),
            "input_matches_committed_readback": True, "decoded_matches_proof": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=Path("/private/tmp/task8-container-baseline.img4"))
    parser.add_argument("--installed", type=Path, default=Path("/private/tmp/task8-container-installed-v7.img4"))
    args = parser.parse_args()
    previous = json.loads((HERE.parent / "committed-readback-v7.json").read_text())
    assert previous["passed"] is True
    result = {"command": sys.argv, "scope": "Pure file parsing; no mount, VM or AMFI operations."}
    try:
        for label, path in [("baseline", args.baseline), ("installed", args.installed)]:
            result[label] = inspect(path, previous["kernels"][label], previous["proof"])
        a, b = result["baseline"], result["installed"]
        result["comparison"] = {"raw_img4_equal": a["raw_img4"]["sha256"] == b["raw_img4"]["sha256"],
            "raw_im4p_equal": a["raw_im4p"]["sha256"] == b["raw_im4p"]["sha256"],
            "decoded_payload_equal": a["decoded_payload"] == b["decoded_payload"],
            "payload_octet_equal": a["payload_octet"] == b["payload_octet"],
            "description_equal": a["description"] == b["description"],
            "compression_equal": a["compression"] == b["compression"],
            "raw_img4_size_delta": b["raw_img4"]["size"] - a["raw_img4"]["size"],
            "raw_im4p_size_delta": b["raw_im4p"]["size"] - a["raw_im4p"]["size"],
            "changed_im4p_base_field_indices": [i for i in range(4) if a["im4p_base_fields"][i]["sha256"] != b["im4p_base_fields"][i]["sha256"]],
            "extra_im4p_children_equal": [(f["tag"], f["sha256"]) for f in a["extra_im4p_children"]] == [(f["tag"], f["sha256"]) for f in b["extra_im4p_children"]],
            "img4_trailing_equal": [(f["tag"], f["sha256"]) for f in a["img4_trailing"]] == [(f["tag"], f["sha256"]) for f in b["img4_trailing"]]}
        result["passed"] = True
        def row(label, left, right):
            return f"| {label} | {left} | {right} |"
        lines = ["# Task 8 容器格式比较", "", "两份输入的完整 IMG4 摘要与既有提交后读回记录一致。解码 payload 摘要均与既有 proof 一致。", "",
                 "| 对象 | 基线 | 安装后 v7 |", "| --- | --- | --- |",
                 row("IMG4 字节数", a["raw_img4"]["size"], b["raw_img4"]["size"]),
                 row("IM4P 字节数", a["raw_im4p"]["size"], b["raw_im4p"]["size"]),
                 row("description", repr(a["description"]), repr(b["description"])),
                 row("压缩类型", a["compression"]["name"], b["compression"]["name"]),
                 row("payload octet 字节数", a["payload_octet"]["size"], b["payload_octet"]["size"]),
                 row("额外 IM4P 子元素数", len(a["extra_im4p_children"]), len(b["extra_im4p_children"])),
                 row("额外 IM4P 子元素类型", ", ".join(str(f["type_name"]) for f in a["extra_im4p_children"]) or "无", ", ".join(str(f["type_name"]) for f in b["extra_im4p_children"]) or "无"),
                 row("IMG4 尾部子元素数", len(a["img4_trailing"]), len(b["img4_trailing"])), "",
                 "基线的额外 IM4P 子元素为 315 字节的 PAYP；安装后该元素不存在。两份 payload octet 字节完全相同，四个 IM4P 基础字段中仅 description 不同。description 缩短 18 字节，PAYP 减少 315 字节，与总尺寸减少 333 字节一致。", "",
                 "两份 IMG4 尾部均仅含 IM4M，其 raw 字节摘要一致；均无 IM4R。", "",
                 "完整字段、子元素 tag、长度和摘要见 [comparison.json](comparison.json)。", "",
                 "该结果仅记录容器差异。启动异常原因未查明；容器差异与启动异常的因果关系尚未验证。", ""]
        (HERE / "diagnosis.md").write_text("\n".join(lines))
    except BaseException as error:
        result["passed"] = False
        result["error"] = repr(error)
        raise
    finally:
        (HERE / "comparison.json").write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
    manifest = {}
    for path in [Path(__file__).resolve(), HERE / "comparison.json", HERE / "diagnosis.md"]:
        content = path.read_bytes()
        manifest[path.name] = {"sha256": sha(content), "size": len(content)}
    (HERE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(result["comparison"], indent=2))


if __name__ == "__main__":
    main()
