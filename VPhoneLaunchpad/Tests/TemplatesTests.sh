#!/bin/zsh
set -euo pipefail

launchpad="${0:a:h:h}"
temporary="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$temporary"' EXIT

# Compile the production option resolver without the Launchpad app and its UI.
{
    print 'enum SlimmingControlFixture {'
    sed -n '/^    private static func slimmingSwitches(/,/^    \/\/\/ Streams the creation log/p' \
        "$launchpad/VPhoneLaunchpad/Control/VPhoneLaunchpadControlCommands.swift" \
        | sed '$d; s/^    private static func slimming(/    static func slimming(/'
    print '}'
} > "$temporary/SlimmingControlFixture.swift"

/usr/bin/xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -module-cache-path "$temporary/module-cache" \
    -parse-as-library \
    "$launchpad/VPhoneLaunchpad/IPSWCache/VPhoneLaunchpadIPSW.swift" \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadBundleStore.swift" \
    "$launchpad/VPhoneLaunchpadShared/VPhoneLaunchpadControl.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadMachine.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadTemplates.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadCreationPlan.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadDiskUsage.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadDiskExtents.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadDiskHolder.swift" \
    "$launchpad/VPhoneLaunchpad/Machines/VPhoneLaunchpadBundleChange.swift" \
    "$launchpad/Tests/TemplatesTests.swift" \
    "$temporary/SlimmingControlFixture.swift" \
    -o "$temporary/templates-tests"
"$temporary/templates-tests" "$@"
