#!/bin/bash
# Build ~/Applications/P.T..app around a macOS build of pt.
# NOTE: re-run this after every rebuild of the build dir, the bundle holds a COPY of the binary.
# usage: tools/make-macos-app.sh [build_dir] [game_dir] [icon.png]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$(cd "${1:-$ROOT/build/macos}" && pwd)"
GAME="${2:-$HOME/Games/pt-pc-game/CUSA01127}"
ICON="${3:-}"
A="$HOME/Applications/P.T..app"
MINOS="$(vtool -show-build "$B/pt" | awk '/minos/{print $2}')"
mkdir -p "$A/Contents/MacOS" "$A/Contents/Resources/game"
# a signed bundle needs a regular-file executable: copy to a temp name, then atomic mv (never write a running binary in place)
cp -f "$B/pt" "$A/Contents/MacOS/.pt.new"
mv -f "$A/Contents/MacOS/.pt.new" "$A/Contents/MacOS/pt"
for d in shaders fonts voice bin licenses; do [ -e "$B/$d" ] && ln -sfn "$B/$d" "$A/Contents/Resources/$d"; done
# the museum/loop preview helpers spawn SDL_GetBasePath()/pt, and the base path is Contents/Resources; a copy, because codesign rejects symlinks to outside the bundle; a symlink to ../MacOS/pt was also refused
cp -f "$A/Contents/MacOS/pt" "$A/Contents/Resources/.pt.new"
mv -f "$A/Contents/Resources/.pt.new" "$A/Contents/Resources/pt"
ln -sfn "$GAME" "$A/Contents/Resources/game/CUSA01127"
cat > "$A/Contents/Info.plist" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleExecutable</key><string>pt</string>
<key>CFBundleIdentifier</key><string>local.ptport.pt</string>
<key>CFBundleName</key><string>P.T.</string>
<key>CFBundleDisplayName</key><string>P.T.</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>PT</string>
<key>CFBundleVersion</key><string>1.0.0</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>LSMinimumSystemVersion</key><string>$MINOS</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.games</string>
<key>NSMicrophoneUsageDescription</key><string>P.T. uses the microphone for one scene (voice recognition).</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
EOP
plutil -lint "$A/Contents/Info.plist"
if [ -n "$ICON" ]; then
  T="$(mktemp -d)"; mkdir "$T/PT.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON" --out "$T/PT.iconset/icon_${s}x${s}.png" >/dev/null
    [ $((s*2)) -le 1024 ] && sips -z $((s*2)) $((s*2)) "$ICON" --out "$T/PT.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$T/PT.iconset" -o "$A/Contents/Resources/PT.icns"; rm -rf "$T"
fi
xattr -cr "$A"
# codesign prints "invalid destination for symbolic link" for the resource symlinks that point outside the bundle
# (shaders, game, ...). The signature is still applied and `--deep` verification passes; only `--strict` complains.
codesign -s - --force --deep "$A" || true
codesign --verify --deep "$A" && echo "built and verified (non-strict) $A (minos $MINOS)"
