#!/bin/zsh
# Runs the unit tests, Release-builds LANNudge and packages it into release/ as a drag-to-install
# DMG (create-dmg: arrow background, app + Applications shortcut). Refuses to package if tests fail.
# Build folders end in .noindex so Spotlight doesn't list build products next to the installed app.
# Needs: brew install xcodegen create-dmg; Finder automation permission (create-dmg lays out the
# window via AppleScript). Adapted from lan-listening-room/scripts/package.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
mkdir -p release build

echo "▶ Unit tests"
xcodebuild -project LANNudge.xcodeproj -scheme LANNudge -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData.noindex test > build/test.log 2>&1 \
  || { echo "✘ tests failed, see build/test.log"; exit 1; }
grep -E "Test run with" build/test.log | tail -1

echo "▶ Release build"
# Command-line settings reach SwiftPM targets too: rewrite the source paths that C code (swift-crypto's
# BoringSSL __FILE__) and debug info embed, and strip the debug symbol table (absolute object-file and
# module paths; the .dSYM keeps them for crash symbolication), so the shipped binary doesn't reveal the builder's home folder.
prefix_map="-ffile-prefix-map=$PWD=."
xcodebuild -project LANNudge.xcodeproj -scheme LANNudge -configuration Release \
  -derivedDataPath build/ReleaseDerivedData.noindex \
  OTHER_CFLAGS="\$(inherited) $prefix_map" OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $PWD=." \
  DEPLOYMENT_POSTPROCESSING=YES STRIP_INSTALLED_PRODUCT=YES STRIP_STYLE=debugging \
  build > build/release.log 2>&1 \
  || { echo "✘ build failed, see build/release.log"; exit 1; }

app=build/ReleaseDerivedData.noindex/Build/Products/Release/LANNudge.app
codesign --verify --deep --strict "$app"
plist="$app/Contents/Info.plist"
version="$(plutil -extract CFBundleShortVersionString raw "$plist")-$(plutil -extract CFBundleVersion raw "$plist")"
display="$(plutil -extract CFBundleDisplayName raw "$plist")"

bg=build/dmg-background.tiff
swiftc -O scripts/make-dmg-background.swift -o build/make-dmg-background
build/make-dmg-background build/dmg-bg.png 1
build/make-dmg-background build/dmg-bg@2x.png 2
tiffutil -cathidpicheck build/dmg-bg.png build/dmg-bg@2x.png -out "$bg" >/dev/null 2>&1

stage=build/dmg.noindex
rm -rf "$stage" && mkdir -p "$stage"
ditto "$app" "$stage/$display.app"
dmg="release/LANNudge-$version.dmg"
rm -f "$dmg"
# create-dmg works on a temporary image next to its output, and the Finder background alias in the
# DMG's .DS_Store records that path. Building in a random temp folder keeps the home folder out of it.
dmg_tmp=$(mktemp -d)
# Icon positions must match scripts/make-dmg-background.swift.
create-dmg --volname "$display" --background "$bg" --window-pos 200 120 --window-size 640 400 \
  --icon-size 128 --text-size 13 --icon "$display.app" 160 180 --hide-extension "$display.app" \
  --app-drop-link 480 180 --filesystem HFS+ --format UDZO --hdiutil-quiet "$dmg_tmp/out.dmg" "$stage" >/dev/null
mv "$dmg_tmp/out.dmg" "$dmg"
rm -rf "$stage" "$dmg_tmp"
echo "✔ $dmg ($(du -h "$dmg" | cut -f1))"

for f in release/*(N); do
  [[ $f == "$dmg" ]] || { rm -f "$f"; echo "  removed old $f"; }
done
