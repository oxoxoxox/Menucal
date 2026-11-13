#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/menucal-regressions.XXXXXX")"
TEST_BUNDLE="$TEST_BUILD_DIR/RegressionResources.bundle"
echo "Regression artifacts: $TEST_BUILD_DIR"
mkdir -p "$TEST_BUNDLE/Contents/Resources"
cp "$REPO_ROOT/Tests/Fixtures/Info.plist" "$TEST_BUNDLE/Contents/Info.plist"
cp "$REPO_ROOT"/MacCalendar/Resources/MenuBarDateIcons/*.png "$TEST_BUNDLE/Contents/Resources/"

xcrun swiftc -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos13.3" \
    -module-cache-path "$TEST_BUILD_DIR/ModuleCache" \
    "$REPO_ROOT/MacCalendar/Core/UpdateManager.swift" \
    "$REPO_ROOT/MacCalendar/Core/HourlyChimeService.swift" \
    "$REPO_ROOT/MacCalendar/Core/SettingsManager.swift" \
    "$REPO_ROOT/MacCalendar/Models/MenuBarDateIconRenderer.swift" \
    "$REPO_ROOT/MacCalendar/Utils/Extensions.swift" \
    "$REPO_ROOT/Tests/RegressionTests.swift" \
    -o "$TEST_BUILD_DIR/regression-tests"

"$TEST_BUILD_DIR/regression-tests" "$TEST_BUNDLE"
