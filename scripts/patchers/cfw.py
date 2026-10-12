#!/usr/bin/env python3
"""
cfw.py — Dynamic binary patching for CFW installation on vphone600.

Uses capstone for disassembly-based anchoring and keystone for instruction
assembly, producing reliable, upgrade-proof patches.

Called by cfw_install.sh during CFW installation.

Commands:
    cryptex-paths <BuildManifest.plist>
        Print SystemOS and AppOS DMG paths from BuildManifest.

    patch-seputil <binary>
        Patch seputil gigalocker UUID to "AA".

    patch-launchd-cache-loader <binary>
        NOP the cache validation check in launchd_cache_loader.

    patch-mobileactivationd <binary>
        Patch -[DeviceType should_hactivate] to always return true.

    patch-launchd-jetsam <binary>
        Patch launchd jetsam panic guard to avoid initproc crash loop.

    patch-hv-vmm-dsc <chunks_dir> [--dry-run]
        Same patch, applied in place to the DSC chunks under
        <chunks_dir> (e.g. /System/Library/Caches/com.apple.dyld inside
        the mounted SystemOS Cryptex). Targets a fixed list of identity,
        store, and consumer-service dylibs; skips compute/accel libs.

    patch-iomfb-swapend <chunks_dir> [--dry-run]
        Patch iOS 26.0 and 26.0.1 IOMobileFramebuffer's _kern_SwapEnd external-method
        payload size from 0x548 to 0x560 for the PCC vphone600 userclient,
        then re-attest the modified DSC page hash.

    patch-iomfb-force-kern <chunks_dir> [--dry-run]
        iOS 27 VZ-view fix: retarget IOMobileFramebuffer's public
        _IOMobileFramebufferSwap* dispatch trampolines to their _kern_Swap*
        siblings, forcing present onto the userclient method-5 path the 26.4
        paravirt GPU scans out to the host (27 defaults to the _virt_* callback
        path the paravirt GPU never receives). Re-attests modified DSC pages.
        Pairs with the KernelJBPatchIomfbSwap kernel patches (accept 27's 0x6e0
        SwapEnd struct).

    patch-dsc-maxslide <chunks_dir> [--dry-run] [--force]
        Zero the dyld_cache_header maxSlide when the userland cache would overflow
        the vphone600 26.x kernel's 6 GiB shared region (cache span + maxSlide >
        0x180000000, e.g. iOS 27.0). Lets the cache map at slide 0 so launchd's dyld
        can map libSystem. Self-gating (no-op if it already fits or maxSlide is
        already 0); a header that fails the dyld_cache_header checks is an error and
        nothing is written. No re-attest needed (header field, not a cs_validate'd
        code page). --force zeroes maxSlide even when the cache fits; it is for
        running this command by hand, and cfw_install.sh never passes it.

    patch-lsd-embedded-reg <chunks_dir> [--dry-run]
        Force lsd's -[_LSDModifyClient clientIsEntitledForEmbeddedRegistrationOperations]
        to always succeed (NOP its entitlement gate + re-attest the page), so app
        (re)registration works on iOS 27 without the three privileged entitlements it
        otherwise demands from the XPC peer. Unblocks vphoned/TrollStore/uicache app
        installs. Self-gating (no-op on pre-iOS-27 userlands where the method is absent).

    patch-xpc-lwcr <chunks_dir> [--dry-run]
    patch-lockdown-mode <chunks_dir> [--dry-run]
        Stop libxpc's Lightweight Code Requirement self-check (_xpc_token_satisfies_lwcr)
        from brk-aborting on our JB. iOS 27's LWCR matcher returns the contradictory
        (matched=0, error_code=MATCH) pair under our code-signing environment; the
        assertion crash-loops every daemon that pins an entitlement peer-requirement
        (intelligencetasksd/searchpartyd/transparencyd/bluetoothd/...). Derives `matched`
        from error_code + drops the abort (cset w0,eq; nop; nop) and re-attests the page.
        Self-gating (no-op on pre-iOS-27 userlands where the symbol is absent).

    patch-camera-dsc <chunks_dir> <dsc_header> [--dry-run] [--force]
        Apply the 10-patch set to the DSC chunks that makes Camera.app
        launch-survivable on a vphone VM: synthesises a single
        `vphone-cam` AVCaptureDevice through `cameracaptured`'s
        device-list / discovery-session / serializer paths and stubs out
        the AVFoundation init-time validation that would otherwise crash
        on the synthetic device. <dsc_header> is the
        dyld_shared_cache_arm64e file (not a chunk) used for
        `ipsw dyld symaddr` symbol resolution.

    patch-watchdogd <binary> [--dry-run]
        Surgical 2-instruction patch of /usr/libexec/watchdogd's
        sysctlbyname("kern.hv_vmm_present", ...) caching block so the
        cached "am I a VM?" byte is forced to 1 regardless of the
        sysctl result. Necessary because the kernel-side OID rename
        makes that sysctl return ENOENT, which would otherwise drive
        watchdogd into a trap path that launchd's _PanicOnCrash
        escalates to a kernel panic. Also recomputes the affected
        CodeDirectory slot hash via cfw_macho_codesign.

    patch-diskimagesiod <binary>
        Force -[DIDiskArb isMountCompleteWithExpectedCount:diskTracker:] to return
        YES so MobileStorageMounter proceeds to mount the iOS-27 personalized DDI at
        /System/Developer (its waitForDAMount otherwise hangs forever on the 26.4
        vphone600 hybrid). Pairs with the DiskImages2 ABI + sandbox
        mac_policy_ops[124] JB kernel patches. No-op-in-effect on matched userlands.

    inject-daemons <launchd.plist> <daemon_dir>
        Inject bash/dropbear/trollvnc into launchd.plist.

    patch-dropbear-plist <dropbear.plist>
        Rewrite dropbear ProgramArguments to use /var/dropbear host keys.

    inject-dylib <binary> <dylib_path>
        Inject LC_LOAD_DYLIB into Mach-O binary (thin or universal).
        Equivalent to: optool install -c load -p <dylib_path> -t <binary>

Dependencies:
    pip install capstone keystone-engine
    ipsw CLI in $PATH (only required for patch-hv-vmm-dsc, experimental variant only)
"""

import os
import sys

# When run as `python3 scripts/patchers/cfw.py`, __name__ is "__main__" and
# relative imports fail. Add the parent directory to sys.path so we can import
# from the patchers package using absolute imports.
if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    from patchers.cfw_patch_seputil import patch_seputil
    from patchers.cfw_patch_cache_loader import patch_launchd_cache_loader
    from patchers.cfw_patch_mobileactivationd import patch_mobileactivationd
    from patchers.cfw_patch_jetsam import patch_launchd_jetsam
    from patchers.cfw_patch_hv_vmm_dsc import patch_hv_vmm_in_dsc
    from patchers.cfw_patch_iomfb_swapend import patch_iomfb_swapend
    from patchers.cfw_patch_iomfb_force_kern import patch_iomfb_force_kern
    from patchers.cfw_patch_dsc_maxslide import patch_dsc_maxslide
    from patchers.cfw_patch_lsd_embedded_reg import patch_lsd_embedded_reg
    from patchers.cfw_patch_xpc_lwcr import patch_xpc_lwcr
    from patchers.cfw_patch_lockdown_mode import patch_lockdown_mode
    from patchers.cfw_patch_camera_dsc import apply_all_camera_patches
    from patchers.cfw_patch_watchdogd import patch_watchdogd
    from patchers.cfw_patch_diskimagesiod import patch_diskimagesiod
    from patchers.cfw_daemons import parse_cryptex_paths, inject_daemons, inject_daemon, patch_dropbear_plist
else:
    from .cfw_patch_seputil import patch_seputil
    from .cfw_patch_cache_loader import patch_launchd_cache_loader
    from .cfw_patch_mobileactivationd import patch_mobileactivationd
    from .cfw_patch_jetsam import patch_launchd_jetsam
    from .cfw_patch_hv_vmm_dsc import patch_hv_vmm_in_dsc
    from .cfw_patch_iomfb_swapend import patch_iomfb_swapend
    from .cfw_patch_iomfb_force_kern import patch_iomfb_force_kern
    from .cfw_patch_dsc_maxslide import patch_dsc_maxslide
    from .cfw_patch_lsd_embedded_reg import patch_lsd_embedded_reg
    from .cfw_patch_xpc_lwcr import patch_xpc_lwcr
    from .cfw_patch_lockdown_mode import patch_lockdown_mode
    from .cfw_patch_camera_dsc import apply_all_camera_patches
    from .cfw_patch_watchdogd import patch_watchdogd
    from .cfw_patch_diskimagesiod import patch_diskimagesiod
    from .cfw_daemons import parse_cryptex_paths, inject_daemons, inject_daemon, patch_dropbear_plist


def _dispatch(*, dry_run=False):
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "cryptex-paths":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py cryptex-paths <BuildManifest.plist>")
            sys.exit(1)
        sysos, appos = parse_cryptex_paths(sys.argv[2])
        print(sysos)
        print(appos)

    elif cmd == "patch-seputil":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-seputil <binary>")
            sys.exit(1)
        if not patch_seputil(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-launchd-cache-loader":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-launchd-cache-loader <binary>")
            sys.exit(1)
        if not patch_launchd_cache_loader(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-mobileactivationd":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-mobileactivationd <binary>")
            sys.exit(1)
        if not patch_mobileactivationd(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-launchd-jetsam":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-launchd-jetsam <binary>")
            sys.exit(1)
        if not patch_launchd_jetsam(sys.argv[2]):
            sys.exit(1)

    elif cmd == "patch-hv-vmm-dsc":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-hv-vmm-dsc <chunks_dir> [--dry-run]")
            sys.exit(1)
        results = patch_hv_vmm_in_dsc(sys.argv[2], dry_run=dry_run)
        sys.exit(0)

    elif cmd == "patch-iomfb-swapend":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-iomfb-swapend <chunks_dir> "
                  "[--target-size <hex|int>] [--dry-run]")
            sys.exit(1)
        kwargs = {}
        if "--target-size" in sys.argv:
            i = sys.argv.index("--target-size")
            kwargs["target_size"] = int(sys.argv[i + 1], 0)
        try:
            patch_iomfb_swapend(sys.argv[2], dry_run=dry_run, **kwargs)
        except ValueError as e:
            print(f"[-] {e}")
            sys.exit(1)
        sys.exit(0)

    elif cmd == "patch-iomfb-force-kern":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-iomfb-force-kern <chunks_dir> [--dry-run]")
            sys.exit(1)
        try:
            patch_iomfb_force_kern(sys.argv[2], dry_run=dry_run)
        except ValueError as e:
            print(f"[-] {e}")
            sys.exit(1)
        sys.exit(0)

    elif cmd == "patch-dsc-maxslide":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-dsc-maxslide <chunks_dir> [--dry-run] [--force]")
            sys.exit(1)
        force = "--force" in sys.argv[3:]
        patch_dsc_maxslide(sys.argv[2], dry_run=dry_run, force=force)
        sys.exit(0)

    elif cmd == "patch-lsd-embedded-reg":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-lsd-embedded-reg <chunks_dir> [--dry-run]")
            sys.exit(1)
        patch_lsd_embedded_reg(sys.argv[2], dry_run=dry_run)
        sys.exit(0)

    elif cmd == "patch-xpc-lwcr":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-xpc-lwcr <chunks_dir> [--dry-run]")
            sys.exit(1)
        patch_xpc_lwcr(sys.argv[2], dry_run=dry_run)

    elif cmd == "patch-lockdown-mode":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-lockdown-mode <chunks_dir> [--dry-run]")
            sys.exit(1)
        patch_lockdown_mode(sys.argv[2], dry_run=dry_run)
        sys.exit(0)

    elif cmd == "patch-camera-dsc":
        if len(sys.argv) < 4:
            print("Usage: patch_cfw.py patch-camera-dsc <chunks_dir> <dsc_header> [--dry-run] [--force]")
            sys.exit(1)
        force   = "--force"   in sys.argv[4:]
        apply_all_camera_patches(sys.argv[2], sys.argv[3], dry_run=dry_run, force=force)
        sys.exit(0)

    elif cmd == "patch-watchdogd":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-watchdogd <binary> [--dry-run]")
            sys.exit(1)
        try:
            n = patch_watchdogd(sys.argv[2], dry_run=dry_run)
        except ValueError as e:
            print(f"[-] {e}")
            sys.exit(1)
        # Exit 0 on both "patched N>0" and "already patched (N==0)".
        # The install script treats both as success; only a raised
        # exception (unparseable binary / no anchor) is fatal.
        sys.exit(0)

    elif cmd == "patch-diskimagesiod":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-diskimagesiod <binary>")
            sys.exit(1)
        if not patch_diskimagesiod(sys.argv[2]):
            sys.exit(1)

    elif cmd == "inject-daemons":
        if len(sys.argv) < 4:
            print("Usage: patch_cfw.py inject-daemons <launchd.plist> <daemon_dir>")
            sys.exit(1)
        inject_daemons(sys.argv[2], sys.argv[3])

    elif cmd == "inject-daemon":
        if len(sys.argv) != 5:
            print("Usage: cfw.py inject-daemon <launchd.plist> <daemon.plist> <launchd_key>")
            sys.exit(1)
        inject_daemon(sys.argv[2], sys.argv[3], sys.argv[4])

    elif cmd == "patch-dropbear-plist":
        if len(sys.argv) < 3:
            print("Usage: patch_cfw.py patch-dropbear-plist <dropbear.plist>")
            sys.exit(1)
        patch_dropbear_plist(sys.argv[2])

    elif cmd == "inject-dylib":
        if len(sys.argv) < 4:
            print("Usage: patch_cfw.py inject-dylib <binary> <dylib_path>")
            sys.exit(1)
        import subprocess, shutil
        insert_dylib_bin = shutil.which("insert_dylib")
        if not insert_dylib_bin:
            # Check .tools/bin/ relative to project root
            project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
            candidate = os.path.join(project_root, ".tools", "bin", "insert_dylib")
            if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                insert_dylib_bin = candidate
        if not insert_dylib_bin:
            print("[-] insert_dylib not found. Run: make setup_tools")
            sys.exit(1)
        rc = subprocess.run(
            [insert_dylib_bin, "--weak", "--inplace", "--all-yes", sys.argv[3], sys.argv[2]],
        ).returncode
        if rc != 0:
            sys.exit(rc)

    elif cmd == "patch-post-restore-dt":
        from .cfw_patch_post_restore_dt import _main
        sys.exit(_main([sys.argv[0]] + sys.argv[2:]))
    elif cmd == "patch-build-version":
        from .cfw_patch_build_version import _main
        sys.exit(_main([sys.argv[0]] + sys.argv[2:]))
    elif cmd == "patch-campo-entitlements":
        from .campo_mach_lookup_exceptions import main as campo_main
        sys.exit(campo_main([sys.argv[0]] + sys.argv[2:]))
    else:
        print(f"Unknown command: {cmd}")
        print("Commands: cryptex-paths, patch-seputil, patch-launchd-cache-loader, patch-camera-dsc,")
        print("          patch-mobileactivationd, patch-launchd-jetsam,")
        print("          patch-hv-vmm-dsc, patch-iomfb-swapend, patch-iomfb-force-kern, patch-dsc-maxslide, patch-lsd-embedded-reg, patch-xpc-lwcr, patch-lockdown-mode, patch-watchdogd,")
        print("          patch-diskimagesiod, inject-daemons, inject-daemon, patch-dropbear-plist, inject-dylib")
        sys.exit(1)


def main():
    if len(sys.argv) < 2 or sys.argv[1] == "cryptex-paths":
        return _dispatch()
    if sys.argv[1] == 'patch-build-version':
        from .cfw_patch_build_version import parse_arguments
        args = parse_arguments(sys.argv[2:])
        sys.argv = [sys.argv[0], sys.argv[1], args.path, args.target] + (['--dry-run'] if args.dry_run else [])
    dry_commands = {"patch-hv-vmm-dsc", "patch-iomfb-swapend", "patch-iomfb-force-kern",
        "patch-dsc-maxslide", "patch-lsd-embedded-reg", "patch-xpc-lwcr", "patch-lockdown-mode",
        "patch-camera-dsc", "patch-watchdogd", "patch-post-restore-dt", "patch-build-version"}
    option_start = 4 if sys.argv[1] in {'patch-build-version', 'patch-camera-dsc'} else 3
    if sys.argv[1] in dry_commands and "--dry-run" in sys.argv[option_start:]:
        return _dispatch(dry_run=True)
    from patchers import plan_gate as gate
    from patchers.guest_write import logical, no_link_parents
    from pathlib import Path
    plan = gate.from_environment()
    gate.require_write_context(plan)
    command = sys.argv[1]
    if '--force' in sys.argv[2:]: raise ValueError('force override has no frozen authorization')
    if command == 'patch-build-version' and (len(sys.argv) < 4 or sys.argv[3] != plan.context['spoofBuild']):
        raise ValueError('build version differs from frozen context')
    from patchers.guest_write import target_table
    table = target_table()[0]
    mapping, dsc = table['commands'], table['dscCommands']
    if len(sys.argv) < 3: raise ValueError("guest patch target missing")
    path = Path(os.path.abspath(sys.argv[2]))
    observations = []
    from patchers import component_effects
    effect_store = Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent / 'effect-blobs'
    source_image = None
    if plan.context['variant'] == 'less':
        from patchers.guest_write import target_table
        target = target_table()[0]['lessCommands'].get(command)
        if target is None: raise ValueError('unknown less filesystem subcommand')
        declaration = 'filesystem-less-cryptex_merge'
        gate.authorize(plan, declaration, target)
        work = Path(plan.context['filesystemTransaction']) / 'work'
        if work not in path.parents or path.is_symlink() or path.name != target.rsplit('/',1)[-1]:
            raise ValueError('less filesystem target outside exact private staging')
        current = path.parent
        while current != work:
            if current.is_symlink(): raise ValueError('linked less staging parent')
            current = current.parent
        if command != 'inject-daemons' and not str(path).endswith(target.removeprefix('system:')):
            raise ValueError('less filesystem target suffix differs')
        observations.append((path, target, gate.snapshot(path), component_effects.capture_input(path, effect_store)))
    elif command in dsc:
        declaration = dsc[command]
        mount = Path(os.environ['CFW_HOST_MNT'])
        if mount not in path.parents or path.is_symlink(): raise ValueError("DSC target outside current staged mounts")
        import re
        if mount / 'mnt_sysos_hv_vmm' in path.parents:
            from patchers.cryptex_source import mounted
            source_image = mounted(plan, mount / 'mnt_sysos_hv_vmm')
        for item in sorted(path.iterdir()):
            if item.name.startswith('dyld_shared_cache_arm64e') and not item.name.endswith('.map') and not re.fullmatch(r"dyld_shared_cache_arm64e(?:\.[0-9]{1,2}|\.symbols)?", item.name):
                raise ValueError("undeclared DSC write member: " + item.name)
            if re.fullmatch(r"dyld_shared_cache_arm64e(?:\.[0-9]{1,2}|\.symbols)?", item.name):
                if item.is_symlink() or not item.is_file():
                    raise ValueError("DSC write target must be a non-linked regular file")
                target = "dsc:/" + item.name
                gate.authorize(plan, declaration, target)
                no_link_parents(item)
                observations.append((item, target, gate.snapshot(item), component_effects.capture_input(item, effect_store)))
        if not observations: raise ValueError("no declared DSC targets")
    else:
        if command == "inject-dylib":
            if len(sys.argv) != 4 or sys.argv[3] not in ('/b','/vh'): raise ValueError("unknown guest dylib target")
            declaration = "system-launchd-jb-hook" if sys.argv[3] == '/b' else "system-launchdaemons-boot-environment"
            target = "system:/sbin/launchd"
        else:
            if command not in mapping: raise ValueError("unknown guest patch command: " + command)
            declaration, target = mapping[command]
        if os.environ.get('VPHONE_DECLARATION_ID', declaration) != declaration: raise ValueError("guest declaration override refused")
        gate.authorize(plan, declaration, target)
        staging = Path(plan.context['vmDirectory']) / '.cfw_temp'
        in_stage = staging in path.parents or (command == 'patch-dropbear-plist' and path == Path(plan.context['vmDirectory']) / 'cfw_input/jb/LaunchDaemons/dropbear.plist')
        if in_stage: gate.private_path(plan, path)
        if not in_stage and logical(path) != target: raise ValueError("patch target differs from declared guest path/staging")
        if not in_stage: no_link_parents(path)
        if path.is_symlink(): raise ValueError("linked guest patch target")
        observations.append((path, target, gate.snapshot(path), component_effects.capture_input(path, effect_store)))
    gate.recheck(plan)
    try:
        return _dispatch()
    finally:
        for item, target, before, effect_input in observations:
            effect = component_effects.capture_change(effect_input, item, effect_store)
            gate.append_evidence(plan, declaration, target, item, before, gate.snapshot(item), source_image=source_image, effect=effect)


if __name__ == "__main__":
    __package__ = 'patchers'
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        print("[-] frozen plan: " + str(error), file=sys.stderr)
        sys.exit(1)
