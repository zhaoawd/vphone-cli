#!/bin/zsh
set -euo pipefail
root="$PWD"
cli="$root/.build/t60-remaining-r3-20261021-cli.app"
app="$root/.build/t60-remaining-r3-20261021.app"
[[ -d "$cli" && ! -e "$app" ]]
# Resign the changed resource tree before the dependency recorder verifies it.
codesign --force --sign - "$cli"
.venv/bin/python scripts/record_build_dependencies.py "$cli"
codesign --force --sign - "$cli"
.venv/bin/python scripts/check_bundle.py "$cli"
cp -cR .build/t60-remaining-r2-20261021.app "$app"
helper="$app/Contents/Helpers/vphone-cli.app"
for name in build.sh build_native_dependencies.py check_bundle.py record_build_dependencies.py run_launchpad_cli_tests.sh; do
  cp -f "$cli/Contents/Resources/scripts/$name" "$helper/Contents/Resources/scripts/$name"
done
cp -f "$cli/Contents/Resources/scripts/licenses/LZ4.txt" "$helper/Contents/Resources/scripts/licenses/LZ4.txt"
cp -f "$cli/Contents/Resources/build-dependencies.json" "$helper/Contents/Resources/build-dependencies.json"
codesign --force --sign - "$helper"
codesign --force --sign - --identifier com.vphone.cli.launchpad "$app"
.venv/bin/python scripts/check_launchpad_bundle.py "$app" --reference "$cli"
