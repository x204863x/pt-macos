# P.T. for macOS (Apple Silicon): install

Needs an Apple Silicon Mac with macOS 14 or newer, and your own copy of the game (the fake PKG `PT.pkg`, title CUSA01127).
Nothing from the game is included in this download.

1. Unzip `P.T.-macOS-arm64-<version>.zip` and move `P.T..app` to `/Applications` (or `~/Applications`).
2. First start: the app is signed ad hoc and not notarized, so macOS blocks it. Open it once (double-click), dismiss the
   warning, then go to System Settings > Privacy & Security, scroll down to "P.T. was blocked", and click "Open Anyway".
   (Or in Terminal: `xattr -dr com.apple.quarantine /Applications/P.T..app`.) This is needed only once.
3. Game files: the game needs three files from your PKG: `chunk1.psarc`, `texture.qar`, `pathid_list_ps4.bin`.
   - Extract them with the helper from the source repository: `tools/macos/extract-pkg.sh /path/to/PT.pkg`
     (needs Rosetta once: `softwareupdate --install-rosetta`). It puts them in
     `~/Library/Application Support/pt-port/game/CUSA01127`, where the app looks first. Or
   - dump the PKG yourself with any tool and, at the first start, choose the folder that holds the three files in the
     dialog the app shows. The choice is remembered.
   The same helper also gives the installed app P.T.'s icon, taken from your own PKG and applied only on your Mac (the app is
   re-signed ad hoc); this download has the default icon. Use `--app <path>` if the app is not in /Applications or
   ~/Applications, `--no-icon` to skip it, or `--icon-only` to apply just the icon.
4. The microphone prompt appears when the voice scene needs it. Allowing it is optional; without it voice recognition does not work.

Settings, saves and the log are in `~/Library/Application Support/pt-port/pt/`. Mods go to `~/Library/Application Support/pt-port/pt/mods/`.
More: docs/macos.md in the repository.
