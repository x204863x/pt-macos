#!/bin/bash
# Manual test of the first-start game-folder dialog. Makes the game data "unfindable" for one launch, runs the app, and
# puts everything back afterwards. Your saves and settings (pt.ini, PT_Save_Data*) and your game folder are never moved or
# deleted. What is touched, and restored at the end: game_dir.txt, the default folder ~/Library/Application Support/pt-port/game
# (renamed away), and pt.log (copied to the report folder first).
#
# usage: tools/macos/test-folder-dialog.sh run [path/to/P.T..app]     (default dist/macos/P.T..app)
#        tools/macos/test-folder-dialog.sh restore                    (only if a run was interrupted)
#        tools/macos/test-folder-dialog.sh report                     (print the last run's evidence)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUP="$HOME/Library/Application Support/pt-port"
USERDIR="$SUP/pt"
STATE="${TMPDIR:-/tmp}/pt-dialog-test"
mkdir -p "$STATE"

restore() {
  [ -f "$STATE/active" ] || { echo "nothing to restore"; return 0; }
  ! pgrep -x pt >/dev/null || { echo "a P.T. process is still running, quit it first, then run: $0 restore" >&2; return 1; }
  cp -f "$USERDIR/pt.log" "$STATE/last-run.log" 2>/dev/null || true
  if [ -f "$USERDIR/game_dir.txt" ]; then cp -f "$USERDIR/game_dir.txt" "$STATE/last-run.game_dir.txt"; else rm -f "$STATE/last-run.game_dir.txt"; fi
  rm -f "$USERDIR/game_dir.txt"
  [ -f "$STATE/game_dir.txt.orig" ] && cp -p "$STATE/game_dir.txt.orig" "$USERDIR/game_dir.txt"
  [ -f "$STATE/pt.log.orig" ] && cp -p "$STATE/pt.log.orig" "$USERDIR/pt.log"
  if [ -d "$SUP/game.moved-by-dialog-test" ]; then
    [ -e "$SUP/game" ] && { echo "WARNING: $SUP/game exists again, the original stays at $SUP/game.moved-by-dialog-test" >&2; } || mv "$SUP/game.moved-by-dialog-test" "$SUP/game"
  fi
  rm -f "$STATE/active"
  echo "restored. Evidence kept in $STATE (last-run.log, last-run.game_dir.txt)."
}

report() {
  echo "--- game_dir.txt after the run: $(cat "$STATE/last-run.game_dir.txt" 2>/dev/null || echo '(none written)')"
  echo "--- last-run.log (first lines and anything about game files):"
  head -4 "$STATE/last-run.log" 2>/dev/null
  grep -n "game files\|psarc\|qar\|vulkan: using\|error" "$STATE/last-run.log" 2>/dev/null | head -10 || true
}

case "${1:-}" in
  restore) restore ;;
  report) report ;;
  run)
    APP="${2:-$ROOT/dist/macos/P.T..app}"
    [ -d "$APP" ] || { echo "app not found: $APP" >&2; exit 1; }
    ! pgrep -x pt >/dev/null || { echo "a P.T. process is running, quit it first" >&2; exit 1; }
    [ ! -f "$STATE/active" ] || { echo "a previous run was not restored: run '$0 restore'" >&2; exit 1; }
    # the app also looks for game/CUSA01127 or CUSA01127 up to five folders above Contents/Resources
    d="$APP/Contents/Resources"; for i in 1 2 3 4 5; do
      for c in "$d/game/CUSA01127" "$d/CUSA01127"; do [ -e "$c" ] && { echo "$c would be found without the dialog; remove it or test another copy of the app" >&2; exit 1; }; done
      d="$(dirname "$d")"; done
    touch "$STATE/active"
    trap restore EXIT
    [ -f "$USERDIR/game_dir.txt" ] && cp -p "$USERDIR/game_dir.txt" "$STATE/game_dir.txt.orig" || rm -f "$STATE/game_dir.txt.orig"
    cp -p "$USERDIR/pt.log" "$STATE/pt.log.orig" 2>/dev/null || rm -f "$STATE/pt.log.orig"
    rm -rf "$STATE/settings-before"; mkdir "$STATE/settings-before"
    cp -p "$USERDIR"/pt.ini "$USERDIR"/PT_Save_Data* "$STATE/settings-before/" 2>/dev/null || true
    rm -f "$USERDIR/game_dir.txt"
    [ -d "$SUP/game" ] && mv "$SUP/game" "$SUP/game.moved-by-dialog-test"
    echo "NOTE: if you play during this test, the game writes its save into the real $USERDIR (the script restores only game_dir.txt and pt.log, never saves or settings)."
    echo "launching $APP ... (this command returns when you quit the app or the dialog's Cancel ends it)"
    open -n -W "$APP"
    for f in "$STATE"/settings-before/*; do
      cmp -s "$f" "$USERDIR/$(basename "$f")" || echo "NOTE: $(basename "$f") changed during the run (a copy from before is in $STATE/settings-before)"
    done
    ;;
  *) sed -n 2,11p "$0"; exit 2 ;;
esac
