#!/bin/bash
# SPDX-FileCopyrightText: Copyright James Martin
# SPDX-License-Identifier: MIT

set -euo pipefail

if (( $# != 7 )); then
    echo "usage: $0 CONFIGURATION OUTPUT_APP VERSION BUILD_NUMBER BUNDLE_ID MINIMUM_SYSTEM_VERSION SIGN_IDENTITY" >&2
    exit 64
fi

configuration=$1
output_app=$2
version=$3
build_number=$4
bundle_id=$5
minimum_system_version=$6
sign_identity=$7

case "$configuration" in
    debug|release) ;;
    *)
        echo "configuration must be debug or release" >&2
        exit 64
        ;;
esac

case "$output_app" in
    .build/*.app) ;;
    *)
        echo "output app must be a .build app bundle: $output_app" >&2
        exit 64
        ;;
esac

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "version must be a semantic version without a leading v: $version" >&2
    exit 64
fi

if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "build number must be a positive integer: $build_number" >&2
    exit 64
fi

executable_path=".build/$configuration/llmenubar"
bundle_executable="$output_app/Contents/MacOS/llmenubar"
bundle_plist="$output_app/Contents/Info.plist"

if [[ ! -x "$executable_path" ]]; then
    echo "built executable not found: $executable_path" >&2
    exit 66
fi

rm -rf -- "$output_app"
mkdir -p -- "$output_app/Contents/MacOS" "$output_app/Contents/Resources"
ditto "$executable_path" "$bundle_executable"
ditto Resources/Info.plist "$bundle_plist"
ditto Resources/AppIcon.icns "$output_app/Contents/Resources/AppIcon.icns"
# The MIT notice must accompany every copy of the binary, and the trademark
# notice covers what the license does not (the name and the logo).
ditto LICENSE "$output_app/Contents/Resources/LICENSE.txt"
# The text file is the Markdown wrapped at 78 columns, so a plain-text viewer
# shows lines of readable length.
fold -s -w 78 TRADEMARKS.md | sed 's/ *$//' > "$output_app/Contents/Resources/TRADEMARKS.txt"
test -s "$output_app/Contents/Resources/LICENSE.txt"
test -s "$output_app/Contents/Resources/TRADEMARKS.txt"

plutil -replace CFBundleIdentifier -string "$bundle_id" "$bundle_plist"
plutil -replace CFBundleShortVersionString -string "$version" "$bundle_plist"
plutil -replace CFBundleVersion -string "$build_number" "$bundle_plist"

require_plist_value() {
    local key=$1
    local expected=$2
    local actual

    actual=$(plutil -extract "$key" raw "$bundle_plist")
    if [[ "$actual" != "$expected" ]]; then
        echo "$key mismatch: expected $expected, found $actual" >&2
        exit 65
    fi
}

require_plist_value CFBundleIdentifier "$bundle_id"
require_plist_value CFBundleShortVersionString "$version"
require_plist_value CFBundleVersion "$build_number"
require_plist_value CFBundleExecutable llmenubar
require_plist_value LSMinimumSystemVersion "$minimum_system_version"
require_plist_value LSArchitectureRequired arm64

architectures=$(lipo -archs "$bundle_executable")
if [[ "$architectures" != arm64 ]]; then
    echo "executable architecture mismatch: expected arm64, found $architectures" >&2
    exit 65
fi

if [[ -z "$sign_identity" ]]; then
    codesign --force --sign - --identifier "$bundle_id" "$output_app"
else
    codesign \
        --force \
        --options runtime \
        --timestamp \
        --sign "$sign_identity" \
        --identifier "$bundle_id" \
        "$output_app"
fi

codesign --verify --deep --strict --verbose=2 "$output_app"
