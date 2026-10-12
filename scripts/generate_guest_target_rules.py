#!/usr/bin/env python3
"""Freeze exact guest targets from local installers and bundled archive member tables."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'scripts/patchers/guest-targets.json'
SWIFT = ROOT / 'sources/FirmwarePatcher/PatchSet/GuestTargetRules.swift'

def render():
    owners = {}
    def add(declaration, *targets):
        for target in targets:
            owners.setdefault(target, [])
            if declaration not in owners[target]: owners[target].append(declaration)
    def system(declaration, *paths): add(declaration, *('system:' + path for path in paths))
    for declaration, filename in [('system-seputil-boot-gigalocker_uuid','seputil'), ('system-launchd_cache_loader-boot-unsecure_cache_gate','launchd_cache_loader'), ('system-mobileactivationd-boot-should_hactivate','mobileactivationd'), ('system-diskimagesiod-cfw-is_mount_complete','diskimagesiod')]:
        system(declaration, '/usr/libexec/' + filename, '/usr/libexec/' + filename + '.bak')
    system('system-launchd-boot-jetsam_panic_guard_bypass','/sbin/launchd','/sbin/launchd.bak')
    system('system-launchd-jb-hook','/sbin/launchd')
    system('system-debugserver-cfw-install','/usr/libexec/debugserver')
    system('system-campo-cfw-entitlements','/Applications/Campo.app/Campo')
    system('system-watchdogd-exp-hv_vmm_cache','/usr/libexec/watchdogd')
    system('system-vphoned-boot-install','/usr/bin/vphoned','/usr/libexec/vphoned-api','/System/Library/LaunchDaemons/vphoned.plist','/System/Library/LaunchDaemons/vphoned-api.plist')
    system('system-launchdaemons-boot-install','/System/Library/xpc/launchd.plist','/System/Library/xpc/launchd.plist.bak', *('/System/Library/LaunchDaemons/'+name+'.plist' for name in ['bash','dropbear','trollvnc','rpcserver_ios']))
    system('system-jb-firstboot-install','/cores/vphone_jb_setup.sh','/cores/vphone_sshd.sh','/cores/vpregister','/System/Library/LaunchDaemons/com.vphone.jb-setup.plist','/System/Library/LaunchDaemons/com.vphone.sshd.plist')
    system('system-jb-basebin-install','/cores','/b', *('/cores/'+name+'.dylib' for name in ['launchdhook','libellekit','systemhook']))
    # These are whole-image copy effects. Their exact source and destination member
    # source relationship and complete member readback are checked before/after copying.
    system('system-cryptex-boot-install','/System/Cryptexes/OS','/System/Cryptexes/App','/System/Library/Caches/com.apple.dyld','/System/DriverKit/System/Library/dyld')
    add('system-gigalocker-boot-rename','hardware:/<gigalocker>.gl')
    add('system-iosbinpack-boot-install','hardware:/dropbear')
    for declaration in ['dyld-exp-hv_vmm','dyld-cfw-camera','dyld-boot-iomfb_swapend','dyld-boot-iomfb_force_kern','dyld-boot-maxslide','dyld-boot-lsd_embedded_reg','dyld-boot-xpc_lwcr','dyld-boot-lockdown_mode']:
        add(declaration, 'dsc:/<chunk>')
    add('preboot-exp-devicetree_identity','preboot:/<boot-hash>/usr/standalone/firmware/devicetree.img4')
    add('system-systemversion-cfw-build_version','system:/System/Library/CoreServices/SystemVersion.plist','preboot:/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist')
    add('preboot-jb-bootstrap-install', *('preboot:/<boot-hash>/'+s for s in ['bootstrap-iphoneos-arm64.tar','org.coolstar.sileo_2.5.1_iphoneos-arm64.deb','jb','jb-vphone','debs']))
    add('preboot-jb-tweakloader-install','preboot:/<boot-hash>/jb-vphone/procursus/usr/lib/TweakLoader.dylib')
    add('preboot-exp-vcam-install', *('preboot:/<boot-hash>/jb-vphone/procursus/Library/MobileSubstrate/DynamicLibraries/'+s for s in ['libvcamcaptured.dylib','libvcamcaptured.plist','libcamfix.dylib','libcamfix.plist']))
    # Library/parent directories created explicitly by the installer.
    add('preboot-exp-vcam-install','preboot:/<boot-hash>/jb-vphone/procursus/Library/MobileSubstrate/DynamicLibraries')
    environment=json.loads((ROOT/'scripts/guest_environment.json').read_text())
    paths=[entry['guest'] for entry in environment['libraries']]+[environment['launchd'],environment['launchd']+'.bak',environment['install_marker'],environment['load_alias']['path'],'System/Library/xpc/launchd.plist',environment['profiles']['v2']['api_daemon']['program'],environment['profiles']['v2']['api_daemon']['plist']]
    system('system-launchdaemons-boot-environment', *('/'+p.lstrip('/') for p in paths))
    for line in (ROOT/'debs.list').read_text().splitlines():
        if line.strip() and not line.lstrip().startswith('#'):
            name=line.split('#')[0].split('?')[0].rsplit('/',1)[-1]
            add('preboot-jb-bootstrap-install','preboot:/<boot-hash>/debs/'+name)
    archives = {}
    def archive(outer, inner, declaration, prefix, compressed=False):
        data = subprocess.check_output(['/usr/bin/tar','-xOf',str(ROOT/'scripts/resources'/outer),inner])
        if compressed: data = subprocess.check_output(['zstd','-dc'],input=data)
        table = {}
        with tarfile.open(fileobj=io.BytesIO(data)) as stream:
            for member in stream:
                name = str(PurePosixPath(member.name))
                if name == '.': continue
                if name.startswith('/') or '..' in PurePosixPath(name).parts: raise ValueError('unsafe bundled member')
                table[name] = {'type': member.type.decode(), 'link': member.linkname}
                if compressed:
                    for sub in [name, str(PurePosixPath('procursus') / PurePosixPath(name).relative_to('var')),
                                str(PurePosixPath('procursus') / PurePosixPath(name).relative_to('var/jb')) if name == 'var/jb' or name.startswith('var/jb/') else name]:
                        add(declaration, prefix+sub)
                else: add(declaration,prefix+name)
        archives[Path(inner).name.removesuffix('.zst')] = table
    archive('cfw_input.tar.zst','cfw_input/jb/iosbinpack64.tar','system-iosbinpack-boot-install','system:/')
    archive('cfw_input.tar.zst','cfw_input/custom/AppleParavirtGPUMetalIOGPUFamily.tar','system-extensions-boot-gpu_bundle','system:/')
    archive('cfw_jb_input.tar.zst','cfw_jb_input/jb/bootstrap-iphoneos-arm64.tar.zst','preboot-jb-bootstrap-install','preboot:/<boot-hash>/jb-vphone/',True)
    system('system-iosbinpack-boot-install','/iosbinpack64.tar')
    system('system-extensions-boot-gpu_bundle','/AppleParavirtGPUMetalIOGPUFamily.tar')
    # Explicit directory metadata has a declaration; descendant writes still need
    # their own exact member. No directory-prefix ownership is used.
    system('system-vphoned-boot-install','/usr/libexec','/System/Library/LaunchDaemons')
    commands={'patch-seputil': ('system-seputil-boot-gigalocker_uuid', 'system:/usr/libexec/seputil'), 'patch-launchd-cache-loader': ('system-launchd_cache_loader-boot-unsecure_cache_gate', 'system:/usr/libexec/launchd_cache_loader'), 'patch-mobileactivationd': ('system-mobileactivationd-boot-should_hactivate', 'system:/usr/libexec/mobileactivationd'), 'patch-launchd-jetsam': ('system-launchd-boot-jetsam_panic_guard_bypass', 'system:/sbin/launchd'), 'patch-watchdogd': ('system-watchdogd-exp-hv_vmm_cache', 'system:/usr/libexec/watchdogd'), 'patch-diskimagesiod': ('system-diskimagesiod-cfw-is_mount_complete', 'system:/usr/libexec/diskimagesiod'), 'patch-dropbear-plist': ('system-launchdaemons-boot-install', 'system:/System/Library/LaunchDaemons/dropbear.plist'), 'inject-daemons': ('system-launchdaemons-boot-install', 'system:/System/Library/xpc/launchd.plist'), 'inject-daemon': ('system-launchdaemons-boot-environment', 'system:/System/Library/xpc/launchd.plist'), 'patch-post-restore-dt': ('preboot-exp-devicetree_identity', 'preboot:/<boot-hash>/usr/standalone/firmware/devicetree.img4'), 'patch-build-version': ('system-systemversion-cfw-build_version', 'system:/System/Library/CoreServices/SystemVersion.plist'), 'patch-campo-entitlements': ('system-campo-cfw-entitlements', 'system:/Applications/Campo.app/Campo')}
    dsc_commands={'patch-hv-vmm-dsc': 'dyld-exp-hv_vmm', 'patch-camera-dsc': 'dyld-cfw-camera', 'patch-iomfb-swapend': 'dyld-boot-iomfb_swapend', 'patch-iomfb-force-kern': 'dyld-boot-iomfb_force_kern', 'patch-dsc-maxslide': 'dyld-boot-maxslide', 'patch-lsd-embedded-reg': 'dyld-boot-lsd_embedded_reg', 'patch-xpc-lwcr': 'dyld-boot-xpc_lwcr', 'patch-lockdown-mode': 'dyld-boot-lockdown_mode'}
    slots={
        'preboot':r'^preboot:/[0-9A-Fa-f]{96}/',
        'hardware':r'hardware:/(?:[0-9A-Fa-f-]{36}|AA)\.gl',
        'dsc':r'dsc:/dyld_shared_cache_arm64e(?:\.[0-9]{1,2}|\.symbols)?',
    }
    tree_targets={target:{'sourceMount':mount,'image':image,'operation':'replace-empty-tree','readback':'exact-types-links-file-sha256','ruleVersion':1} for target,mount,image in [
        ('system:/System/Cryptexes/OS','mnt_sysos','CryptexSystemOS.dmg'),
        ('system:/System/Cryptexes/App','mnt_appos','CryptexAppOS.dmg')]}
    less_commands={'patch-mobileactivationd':'system:/usr/libexec/mobileactivationd','patch-launchd-cache-loader':'system:/usr/libexec/launchd_cache_loader','inject-daemons':'system:/System/Library/xpc/launchd.plist'}
    targets = json.dumps({'schemaVersion':1,'owners':owners,'archives':archives,'lessCommands':less_commands,'commands':commands,'dscCommands':dsc_commands,'slots':slots,'treeTargets':tree_targets},sort_keys=True,separators=(',',':')).encode()
    digest=hashlib.sha256(targets).hexdigest()
    ids=sorted({i for values in owners.values() for i in values})
    swift='''// Generated by scripts/generate_guest_target_rules.py. Exact target-table identity.
import Foundation

enum GuestTargetRules {
    static let digest = "'''+digest+'''"
    static let declarationIDs: Set<String> = [
'''+''.join('        '+json.dumps(i)+',\n' for i in ids)+'''    ]
    static func rules(for id: String) -> [DeclarationRecordRule]? {
        guard declarationIDs.contains(id) else { return nil }
        return [DeclarationRecordRule(literal: "guest-target-map-v1:" + digest + ":" + id)]
    }
}
'''
    return targets,swift

if __name__ == '__main__':
    ap=argparse.ArgumentParser(); ap.add_argument('--check',action='store_true'); args=ap.parse_args()
    targets,swift=render()
    if args.check:
        if OUT.read_bytes()!=targets or SWIFT.read_text()!=swift: raise SystemExit('guest target rules differ')
        print('Guest target table and frozen catalog rules match')
    else: OUT.write_bytes(targets); SWIFT.write_text(swift)
