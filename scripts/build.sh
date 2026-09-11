#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
build_args=(-c release)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    build_args+=(--arch arm64 --arch x86_64)
fi
swift build "${build_args[@]}"
bin_dir=$(swift build "${build_args[@]}" --show-bin-path)

app="$HOME/Applications/Plaintexter.app"
mkdir -p "${app:h}"
staging_dir=$(mktemp -d "${app:h}/.Plaintexter-build.XXXXXX")
cleanup() {
    # Restore the previous bundle if installation failed after moving it aside.
    if [[ -d "$staging_dir/Previous.app" && ! -e "$app" ]]; then
        mv "$staging_dir/Previous.app" "$app"
    fi
    rm -rf "$staging_dir"
}
trap cleanup EXIT

staged_app="$staging_dir/Plaintexter.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$bin_dir/Plaintexter" "$staged_app/Contents/MacOS/Plaintexter"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
cp Resources/AppIcon.icns "$staged_app/Contents/Resources/AppIcon.icns"
plutil -lint "$staged_app/Contents/Info.plist"
if [[ -n "${SIGNING_IDENTITY:-}" && "$SIGNING_IDENTITY" != - ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$staged_app"
else
    codesign --force --sign - "$staged_app"
fi
codesign --verify --deep --strict "$staged_app"

if [[ -e "$app" ]]; then
    mv "$app" "$staging_dir/Previous.app"
fi
mv "$staged_app" "$app"
print -r -- "$app"
