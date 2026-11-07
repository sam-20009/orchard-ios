#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
python3 scripts/create_samples.py "$TEMP_DIR/fixtures"
swiftc AetherXR/PackageAnalyzer.swift Tests/PackageSmoke.swift -o "$TEMP_DIR/aether-package-smoke"
"$TEMP_DIR/aether-package-smoke" "$TEMP_DIR/fixtures"
