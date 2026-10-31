#!/usr/bin/env python3
"""Prepare a generation-backed readonly-source candidate; never touch a VM disk."""
import json
from pathlib import Path
import plistlib
import sys

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'scripts'))
from patchers import guest_undo,undo_provenance
from cache_systemos import cache_systemos
import cfw_guest_evidence as evidence


def main():
    vm=ROOT/'vm-t32-t33-dsc-20261018'
    archive=vm/'.cfw-history/20261020T145635Z-QBLOIoqy'
    generation='6ebc5f6705cf0bffb32da62bf3006cc7ece5027edee4306abc8031aee9f4bb42'
    plan=guest_undo.saved_plan(archive,generation)
    root=vm/'.firmware-generations'/generation/'originals/iPhone17,3_26.0_23A341_Restore'
    manifest=plistlib.loads((root/'iPhone-BuildManifest.plist').read_bytes())
    # The source manifest also contains a recovery OS image. Qualify the
    # customer erase identity explicitly; recovery is a different input.
    identities=[row for row in manifest['BuildIdentities']
                if row.get('Info',{}).get('Variant')=='Customer Erase Install (IPSW)']
    if len(identities)!=1:raise ValueError('Ambiguous customer erase identity')
    sources={row['Manifest']['OS']['Info']['Path'] for row in identities}
    if len(sources)!=1:raise ValueError('Ambiguous original root filesystem')
    relative=Path(next(iter(sources)))
    if relative.is_absolute() or '..' in relative.parts:raise ValueError('Invalid original image path')
    source=root/relative
    before=undo_provenance.qualify_source(plan,source)
    work=ROOT/'.build/t32-t33-completion-20261023/file-original-source'
    work.mkdir(mode=0o700)
    cache=work/'pristine-rootfs.dmg'
    cache_systemos(source,cache)
    after=undo_provenance.qualify_source(plan,source)
    if before!=after:raise ValueError('Generation input changed during source preparation')
    report=dict(schemaVersion=1,state='prepared-source-image-not-undo-authority',
                generationID=generation,vm=str(vm),source=str(source),generationSource=after,
                cache=str(cache),cacheSHA256=evidence.digest(cache),mounted=False,
                originQualified=False,writeAuthorized=False,runtimeValidated=False)
    evidence.write_new(work/'source.json',evidence.canonical(report))
    print(json.dumps(dict(state=report['state'],cache=str(cache),sha256=report['cacheSHA256'])))


if __name__=='__main__':main()
