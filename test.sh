#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
  Sources/Archive.swift Sources/Layout.swift Sources/ExportPolicy.swift Sources/TaskLogHistory.swift Tests/main.swift -framework CryptoKit -o .build/archive-tests
.build/archive-tests
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.build/module-cache" \
  Sources/Archive.swift Sources/Layout.swift Sources/DirectoryCopy.swift Tests/Directory/main.swift \
  -framework CryptoKit -o .build/directory-tests
.build/directory-tests
xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/.build/module-cache" \
  Sources/Archive.swift Sources/Layout.swift Sources/DirectoryCopy.swift Tests/Memory/main.swift \
  -framework CryptoKit -o .build/memory-tests
.build/memory-tests
