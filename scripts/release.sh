#!/bin/zsh
# Build a universal app, notarize and staple it, then package and notarize a DMG.
# Set NOTARY_PROFILE to an existing notarytool Keychain profile.
set -euo pipefail
cd "${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your notarytool Keychain profile name.}"
export SIGNING_IDENTITY="${SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk -F '"' '/Developer ID Application:/ {print $2; exit}')}"
[[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]] || {
    print -u2 -- "A Developer ID Application signing identity is required."
    exit 1
}
export UNIVERSAL=1
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
app="$HOME/Applications/Plaintexter.app"
output_dir="${OUTPUT_DIR:-$HOME/Applications/Plaintexter Releases}"
work="$PWD/.build/release-$version"
mkdir -p "$work" "$output_dir"

# Check credentials before replacing the local app or starting a release build.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > "$work/credential-check.json"
swift test -c release
./scripts/build.sh

notarize() {
    local archive="$1" log="$2"
    xcrun notarytool submit "$archive" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$log"
    python3 - "$log" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print("Notarization:", result.get("status"), "—", result.get("id"))
if result.get("status") != "Accepted":
    raise SystemExit("Notarization did not succeed. Check the submission log before distributing.")
PY
}

ditto -c -k --sequesterRsrc --keepParent "$app" "$work/Plaintexter-submit.zip"
notarize "$work/Plaintexter-submit.zip" "$work/app-notarization.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"

# Packaging tools stay in a project-local virtual environment; the app has no dependencies.
if [[ ! -x .build/dmg-venv/bin/dmgbuild ]]; then
    python3 -m venv .build/dmg-venv
    .build/dmg-venv/bin/pip install 'dmgbuild==1.6.7'
fi
swift scripts/generate-dmg-background.swift
dmg="$work/Plaintexter-$version.dmg"
.build/dmg-venv/bin/python scripts/build-dmg.py "$app" "$dmg"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$dmg"
notarize "$dmg" "$work/dmg-notarization.json"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict "$dmg"
hdiutil verify "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

cp "$dmg" "$output_dir/.Plaintexter-$version.dmg.tmp"
mv "$output_dir/.Plaintexter-$version.dmg.tmp" "$output_dir/Plaintexter-$version.dmg"
(cd "$output_dir" && shasum -a 256 "Plaintexter-$version.dmg" > "Plaintexter-$version.dmg.sha256")
print -r -- "$output_dir/Plaintexter-$version.dmg"
