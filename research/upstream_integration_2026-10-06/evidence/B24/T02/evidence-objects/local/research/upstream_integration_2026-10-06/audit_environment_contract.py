#!/usr/bin/env python3
"""Audit literal environment lists against a fixed upstream Git object.

This reads source, not a running VM. It deliberately fails if the declaration
shape changes instead of returning an empty list as a successful comparison.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

TARGET = "2d21d21fbdd4f51f013616273ceda9b35a3e0789"
ROOT = Path(__file__).resolve().parents[2]

def literal_list(source, key):
    match = re.search(r"(?:public\s+)?static let " + re.escape(key) + r"\s*=\s*\[([^\]]+)\]", source)
    if not match:
        raise ValueError(f"Cannot locate literal list {key}")
    names = re.findall(r'"([^"\n]+\.dylib)"', match.group(1))
    if not names or len(names) != len(set(names)):
        raise ValueError(f"Empty or duplicate list {key}")
    return names

def audit(git_dir):
    sources = []
    def local(path):
        data = (ROOT / path).read_bytes()
        sources.append({"scope": "local", "path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        return data.decode()
    def upstream(path):
        data = subprocess.check_output(["git", "--git-dir", git_dir, "show", TARGET + ":" + path])
        sources.append({"scope": "upstream", "target": TARGET, "path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        return data.decode()
    manifest = json.loads(local("scripts/guest_environment.json"))
    names = [row["name"] for row in manifest["libraries"]]
    guest = local("sources/VPhoneDaemon/Daemon/GuestAPI+Environment.swift")
    host = local("sources/vphone-cli/VPhoneGuestEnvironment.swift")
    local("sources/vphone-cli/VPhoneGuestEnvironmentCLI.swift")
    local("scripts/cfw_install_host.sh")
    local("scripts/cfw_disk_txn.py")
    health = local("sources/VPhoneDaemon/Daemon/GuestAPI.swift")
    local("sources/VPhoneAPIKit/VPhoneAPIClient.swift")
    local("sources/VPhoneDaemon/Daemon/Wire/APIFileUploadTransaction.swift")
    if names != literal_list(guest, "environmentLibraries") or len(names) != len(set(names)):
        raise ValueError("Local manifest and daemon lists disagree")
    # The host reads the manifest, rather than keeping another literal list.
    if 'object["libraries"] as? [[String: Any]]' not in host or 'before.names == manifest.names' not in host:
        raise ValueError("Host manifest/list checks changed; review manually")
    methods = sorted(set(re.findall(r'case "(environment\.[a-z]+)"', guest)))
    if methods != ["environment.install", "environment.loaded", "environment.restore", "environment.status"]:
        raise ValueError("Environment dispatch changed; review manually")
    capabilities = sorted(set(re.findall(r'"(environment_[a-z]+)"', health)))
    if capabilities != ["environment_activation", "environment_transaction", "environment_update"]:
        raise ValueError("Environment capabilities changed; review manually")
    upstream_guest = upstream("VPhoneDaemon/Daemon/GuestAPI+Environment.swift")
    upstream_host = upstream("VPhoneKit/VPhoneCoreKit/VirtualMachine/VPhoneGuestEnvironment.swift")
    upstream("VPhoneExecutable/VPhoneVirtualization/UI/GuestCommunication/VPhoneGuestControlEnvironment.swift")
    upstream_doc = upstream("Research/vphoned_http_api.md")
    upstream_names = literal_list(upstream_guest, "environmentLibraries")
    if upstream_names != literal_list(upstream_host, "libraries"):
        raise ValueError("Upstream host and guest lists disagree")
    paragraph = upstream_doc.split("The environment update keeps ", 1)[1].split("The profile UDID methods", 1)[0]
    documented = list(dict.fromkeys(re.findall(r'`([^`]+\.dylib)`', paragraph)))
    if not documented:
        raise ValueError("Cannot identify upstream documented list")
    return {"target": TARGET, "runtime_verified": False,
            "local_libraries": names, "local_methods": methods, "local_environment_capabilities": capabilities,
            "upstream_libraries": upstream_names, "upstream_documented_libraries": documented,
            "upstream_documentation_matches_source": documented == upstream_names,
            "local_only": sorted(set(names) - set(upstream_names)),
            "upstream_only": sorted(set(upstream_names) - set(names)), "sources": sources}

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--upstream-git-dir", required=True)
    parser.add_argument("--document", type=Path)
    args = parser.parse_args()
    result = audit(args.upstream_git_dir)
    if args.document:
        text = args.document.read_text()
        section = text.split("<!-- local-libraries -->", 1)[1].split("<!-- /local-libraries -->", 1)[0]
        recorded = re.findall(r"^\| `([^`]+\.dylib)` \|", section, re.MULTILINE)
        if recorded != result["local_libraries"]:
            raise ValueError("Documented local libraries disagree with source")
        result["local_document_list_verified"] = True
    print(json.dumps(result, ensure_ascii=False, indent=2))
