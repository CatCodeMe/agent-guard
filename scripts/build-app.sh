#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release
binary_dir=$(swift build -c release --show-bin-path)
app_dir="build/Agent Guard.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$binary_dir/AgentGuard" "$app_dir/Contents/MacOS/AgentGuard"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODE_SIGN_IDENTITY" \
    --entitlements Resources/AgentGuard.entitlements "$app_dir"
else
  codesign --force --sign - "$app_dir"
fi
codesign --verify --strict "$app_dir"
if [[ -n "${CODE_SIGN_IDENTITY:-}" ]]; then
  printf 'Built %s (signed with %s; entitlement profile supplied, notarization not verified)\n' "$app_dir" "$CODE_SIGN_IDENTITY"
else
  printf 'Built %s (local ad-hoc signature; Endpoint Security entitlement is not active)\n' "$app_dir"
fi
