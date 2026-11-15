#!/bin/zsh
set -euo pipefail
root=${0:a:h:h:h}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/vphone-nested-env.XXXXXXXX")
trap 'rm -rf "$temporary"' EXIT
stage=${VPHONE_STAGE_BUNDLE_SOURCE:-$root/VPhoneExecutable/VPhoneVirtualization/Build/StageBundle.sh}
project=${VPHONE_DAEMON_PROJECT:-$root/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.pbxproj}
plutil -convert json -o "$temporary/project.json" "$project"
node --input-type=module - "$stage" "$temporary" <<'JS'
import fs from 'node:fs';const [stage,dir]=process.argv.slice(2);const text=fs.readFileSync(stage,'utf8');let fn=text.match(/^build_project\(\) \{[\s\S]*?^\}/m)?.[0];if(!fn)throw Error('Production build_project missing');fn=fn.replace('/usr/bin/xcodebuild','"$VPHONE_ENV_PROBE"');fs.writeFileSync(dir+'/stage.zsh',fn+'\nbuild_project fixture\n');const project=JSON.parse(fs.readFileSync(dir+'/project.json'));const phase=Object.values(project.objects).find(o=>o.isa==='PBXShellScriptBuildPhase'&&o.shellScript?.includes('-scheme VPhoneSign'));if(!phase||phase.showEnvVarsInLog!=='0'&&phase.showEnvVarsInLog!==0)throw Error('Signer build phase must hide environment logging');fs.writeFileSync(dir+'/signer.zsh',phase.shellScript.replace('/usr/bin/xcodebuild','"$VPHONE_ENV_PROBE"'));if(!text.includes('-hideShellScriptEnvironment')||!phase.shellScript.includes('-hideShellScriptEnvironment'))throw Error('Nested build must hide shell phase environments');
JS
cat > "$temporary/probe" <<PROBE
#!/bin/zsh
set -euo pipefail
/usr/bin/env > '$temporary/received'
PROBE
chmod +x "$temporary/probe"
export VPHONE_ENV_PROBE="$temporary/probe"
export SRCROOT="$root/VPhoneDaemon" CONFIGURATION=Debug PLATFORM_NAME=iphoneos EFFECTIVE_PLATFORM_NAME=-iphoneos
export VPHONE_NOT_FORWARDED=must-not-leak
export SDKROOT=caller-sdk-must-not-leak
export DEVELOPER_DIR=$(xcode-select -p)
export SWIFTPM_NETRC_DATA=fixture-auth-only
export SWIFTPM_MIRROR_CONFIG='fixture mirror config'
for entry in stage signer; do
    zsh "$temporary/$entry.zsh"
    rg -q '^SWIFTPM_NETRC_DATA=fixture-auth-only$' "$temporary/received"
    rg -q '^SWIFTPM_MIRROR_CONFIG=fixture mirror config$' "$temporary/received"
    rg -q '^DEVELOPER_DIR=' "$temporary/received"
    if rg -q '^(SDKROOT|VPHONE_NOT_FORWARDED)=' "$temporary/received"; then
        print -u2 "$entry leaked unrelated parent state"; exit 1
    fi
done
unset SWIFTPM_NETRC_DATA SWIFTPM_MIRROR_CONFIG DEVELOPER_DIR
for entry in stage signer; do
    zsh "$temporary/$entry.zsh"
    if rg -q '^(SWIFTPM_NETRC_DATA|SWIFTPM_MIRROR_CONFIG|DEVELOPER_DIR|SDKROOT|VPHONE_NOT_FORWARDED)=' "$temporary/received"; then
        print -u2 "$entry invented optional or unrelated parent state"; exit 1
    fi
done
print 'Nested build environment: explicit auth/mirrors retained, absent options omitted, SDK/unrelated state excluded, shell logs hidden'
