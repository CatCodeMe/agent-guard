#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
app_dir="build/Agent Guard.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/AgentGuard" "$app_dir/Contents/MacOS/AgentGuard"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
codesign --force --sign - "$app_dir"
codesign --verify --strict "$app_dir"
printf 'Built %s (local development signature, not notarized)\n' "$app_dir"
