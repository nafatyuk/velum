#!/bin/zsh
# Runs the tests. With only the Command Line Tools, swift-build sometimes loses track of Swift Testing's
# macro plugin ("plugin for module 'TestingMacros' not found"); naming the active toolchain's plugin folder
# makes every run find it. Works with Xcode's toolchain too.
set -euo pipefail
cd "${0:A:h}/.."
plugins="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [[ -d "$plugins" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$plugins" "$@"
fi
exec swift test "$@"
