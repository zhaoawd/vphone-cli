#!/bin/zsh
set -euo pipefail
root="${0:a:h:h:h:h:h}"
cd "$root"
mode="${1:-native}"
[[ "$mode" == native || "$mode" == poweroff ]] || exit 64
products="$root/.build/launchpad-907.FUmycAhy/CoreKit/Build/Products/Debug"
baseline="$root/.build/duo-fixes-20261114/baseline/VPhone.bundle"
machine="$root/.build/duo-runtime-84e3ce54/machines/duo-template-reboot-20261114"
out=$(mktemp -d "$root/.build/review-20261114/template-$mode.XXXXXXXX")
print -r -- "$out"
cp "${0:a}" "$out/driver.zsh"
if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/handles-before.txt"; then exit 1; fi
{
    print 'import Foundation'
    print 'import VPhoneCoreKit'
    sed -n '/^final class VPhoneTemplateSetupVirtualMachine:/,/^\/\/ MARK: - Running a setup boot/p' \
        VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneTemplateSetup.swift | sed '$d'
    print 'extension VPhoneTemplateSetupVirtualMachine {'
    print '    var regressionOutput: String { process?.outputText ?? "" }'
    print '    var regressionRunning: Bool { process?.isRunning ?? false }'
    print '}'
} > "$out/ProductionMachine.swift"
cp "${0:a:h}/template-reboot-runtime.swiftfrag" "$out/NativeTemplateRebootRegression.swift"
shasum -a 256 VPhoneKit/VPhoneCoreKit/Bundle/VPhoneTemplateSetupBoot.swift \
    VPhoneExecutable/VPhoneCommand/VPhoneCommand/VirtualMachine/VPhoneTemplateSetup.swift > "$out/source-hashes.txt"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -module-cache-path "$out/module-cache" -I "$products" -L "$products" -lVPhoneCoreKit \
    VPhoneExecutable/VPhoneCommand/VPhoneCommand/Host/VPhoneHostAutomationProbe.swift \
    "$out/ProductionMachine.swift" "$out/NativeTemplateRebootRegression.swift" \
    -o "$out/template-reboot-runtime"
ln -s "$baseline/Contents/MacOS/vphone-vm" "$out/vphone-vm"
mkdir -p "$out/host-home"
run_status=0
CFFIXED_USER_HOME="$out/host-home" NSUnbufferedIO=YES "$out/template-reboot-runtime" \
    "$machine" "$baseline/Contents/Resources" "$out" "$mode" > "$out/runtime.log" 2>&1 || run_status=$?
if lsof "$machine/Disk.img" "$machine/nvram.bin" "$machine/SEPStorage" > "$out/open-handles.txt"; then
    print -u2 'VM state files remain open'
    exit 1
fi
(( run_status == 0 )) || { cat "$out/runtime.log"; exit "$run_status"; }
cat "$out/summary.json"
