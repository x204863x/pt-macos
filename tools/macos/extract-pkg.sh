#!/bin/bash
# Extract the three game files the port needs from your own PT.pkg (CUSA01127). The PKG is only read, never modified.
# usage: tools/macos/extract-pkg.sh [--app <P.T..app>] [--icon-only] [--no-icon] <PT.pkg> [dest]
#   dest defaults to ~/Library/Application Support/pt-port/game/CUSA01127
#   Also gives the installed app the game's icon, taken from your own PKG (ICON0_PNG), locally: the icon is never part of the
#   release or this repository. The app is --app, else /Applications/P.T..app, else ~/Applications/P.T..app; none found: skipped.
#   The app is re-signed ad hoc afterwards. --icon-only: only the icon, no game files. --no-icon: only the game files.
# Uses LibOrbisPkg's PkgTool.Core (MIT, https://github.com/maxton/LibOrbisPkg), downloaded and verified by SHA-256.
# It is an x86_64 build: Apple silicon runs it through Rosetta 2.
set -euo pipefail

URL="https://github.com/maxton/LibOrbisPkg/releases/download/v0.2/PkgTool.Core-osx-x64-0.2.231.zip"
SHA256="ddc958efe27e01ea9eadad0593f3091c76ff7225ebc5c02d7d6d500fbaec7e37"
FILES=(chunk1.psarc texture.qar pathid_list_ps4.bin)

APP=""; ICON=1; FILES_TOO=1
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="${2:-}"; shift 2 ;;
    --icon-only) FILES_TOO=0; shift ;;
    --no-icon) ICON=0; shift ;;
    *) break ;;
  esac
done
PKG="${1:-}"
DEST="${2:-$HOME/Library/Application Support/pt-port/game/CUSA01127}"
[ -n "$PKG" ] && [ -f "$PKG" ] || { echo "usage: $0 [--app <P.T..app>] [--icon-only] [--no-icon] <PT.pkg> [dest]" >&2; exit 2; }
PKG="$(cd "$(dirname "$PKG")" && pwd)/$(basename "$PKG")"

if [ "$(uname -m)" = arm64 ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
  echo "Rosetta 2 is not installed (PkgTool.Core is an Intel build). Install it with:" >&2
  echo "  softwareupdate --install-rosetta --agree-to-license" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "downloading PkgTool.Core 0.2.231 ..."
curl -fsSL -o "$TMP/pkgtool.zip" "$URL"
GOT="$(shasum -a 256 "$TMP/pkgtool.zip" | awk '{print $1}')"
if [ "$GOT" != "$SHA256" ]; then
  echo "checksum mismatch for PkgTool.Core ($GOT), aborting" >&2
  exit 1
fi
mkdir "$TMP/tool"
unzip -q "$TMP/pkgtool.zip" -d "$TMP/tool"
chmod +x "$TMP/tool/PkgTool.Core"
xattr -cr "$TMP/tool" 2>/dev/null || true

if [ "$FILES_TOO" = 1 ]; then
  echo "extracting (this reads the whole PKG, it can take a few minutes) ..."
  (cd "$TMP" && "$TMP/tool/PkgTool.Core" pkg_extract "$PKG" "$TMP/out")

  mkdir -p "$DEST"
  for f in "${FILES[@]}"; do
    src="$(find "$TMP/out" -name "$f" -type f | head -n 1)"
    [ -n "$src" ] || { echo "$f not found in the PKG" >&2; exit 1; }
    cp -f "$src" "$DEST/$f"
    echo "  $f"
  done
  echo "done: $DEST"
fi

# --- the app icon, from the PKG's ICON0_PNG entry (found through the entry table, not by offset) ---
if [ "$ICON" = 1 ]; then
  if [ -z "$APP" ]; then
    for c in "/Applications/P.T..app" "$HOME/Applications/P.T..app"; do [ -d "$c" ] && { APP="$c"; break; }; done
  fi
  if [ -z "$APP" ] || [ ! -d "$APP" ]; then
    echo "no P.T..app found, skipping the icon (use --app <path>)"
    exit 0
  fi
  ID="$("$TMP/tool/PkgTool.Core" pkg_listentries "$PKG" | awk '$NF=="ICON0_PNG"{print $4; exit}')"
  if [ -z "$ID" ]; then echo "no ICON0_PNG entry in the PKG, skipping the icon" >&2; exit 0; fi
  "$TMP/tool/PkgTool.Core" pkg_extractentry "$PKG" "$ID" "$TMP/icon0.png"
  mkdir "$TMP/PT.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon0.png" --out "$TMP/PT.iconset/icon_${s}x${s}.png" >/dev/null
    [ $((s*2)) -le 1024 ] && sips -z $((s*2)) $((s*2)) "$TMP/icon0.png" --out "$TMP/PT.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/PT.iconset" -o "$TMP/PT.icns"
  cp -f "$TMP/PT.icns" "$APP/Contents/Resources/PT.icns"
  plutil -replace CFBundleIconFile -string PT "$APP/Contents/Info.plist"
  BID="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
  xattr -cr "$APP"
  codesign -s - --force --deep --identifier "$BID" "$APP"
  codesign --verify --deep --strict "$APP"
  touch "$APP"
  echo "icon applied to $APP (re-signed ad hoc and verified)"
fi
