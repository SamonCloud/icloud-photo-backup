#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
  Sources/Archive.swift Sources/Layout.swift Sources/ExportPolicy.swift Tests/main.swift -framework CryptoKit -o .build/archive-tests
.build/archive-tests
