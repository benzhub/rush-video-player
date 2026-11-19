#!/bin/bash
# 只裝 Command Line Tools（沒有 Xcode）時，swift-testing 的 macro plugin 和 framework 不在預設路徑，需要手動指定
set -euo pipefail
cd "$(dirname "$0")/.."

if xcode-select -p | grep -q CommandLineTools; then
    CLT=/Library/Developer/CommandLineTools
    exec swift test \
        -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
        -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" "$@"
else
    exec swift test "$@"
fi
