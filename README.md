# P.T. for macOS

A macOS (Apple Silicon) build of [LoreanXavier/pt-pc](https://github.com/LoreanXavier/pt-pc), the native PC port of P.T., the 2014 PS4
teaser by Kojima Productions. It is not an emulator: the game logic was rebuilt in C++ from the original's behaviour, the renderer is
written on Vulkan (running on Metal through MoltenVK here), and every level, model, texture, sound, script and cutscene is read at run
time from your own copy of the game. There is no game data in this repository or in the releases.

This is an unofficial fork, kept in sync with the original project; the port itself is LoreanXavier's work. P.T. is the work of Kojima
Productions and is owned by Konami; this project is not affiliated with, endorsed by or connected to either of them.

## What you need

- An Apple Silicon Mac (M1 or newer) with macOS 14 or newer. It was tested on macOS 26 with an M4 only; macOS 14 and 15 and other chips
  are not verified. Intel Macs are not supported.
- Your own copy of P.T., the US release CUSA01127, as a fake PKG or a dump. A store PKG cannot be used: it is encrypted for the console
  that owns it, and nothing here decrypts it.
- A microphone for one part of the game, as on the PS4. Without one, `key = J` under `[voice]` in `pt.ini` lets a key stand in for the
  spoken word.

## Install

1. Download `P.T.-macOS-arm64-<version>.zip` from the Releases page, unzip it and move `P.T..app` to Applications.
2. The app is ad-hoc signed and not notarized, so macOS blocks the first start: open it once, then System Settings > Privacy & Security >
   Open Anyway.
3. Get the three game files (`chunk1.psarc`, `texture.qar`, `pathid_list_ps4.bin`) from your own PKG with
   `tools/macos/extract-pkg.sh /path/to/PT.pkg`. It also gives the app P.T.'s icon, taken from your own PKG and applied only on your Mac.
   Or skip that and choose the folder that holds your dump's three files in the dialog the app shows at the first start; the choice is
   remembered.

The steps in full are in [tools/macos/INSTALL-macOS.md](tools/macos/INSTALL-macOS.md) (also attached to each release) and
[docs/macos.md](docs/macos.md).

## Playing

Mouse and WASD, right mouse button to zoom, left button, Enter or E to interact, Esc for the pause menu, Alt+Enter for fullscreen, F10 for
the PC settings. Gamepads are meant to work as the PS4 pad (not tested on macOS). The in-game options (brightness, subtitles, camera
inversion) are the original ones.

Settings (`pt.ini`), the save, the log (`pt.log`) and mods live in `~/Library/Application Support/pt-port/pt/`.

## What the port adds

These come from the original port; they are not all re-tested on macOS. Everything is off or at the original's behaviour by default.

- Window, borderless or fullscreen, any resolution, v-sync; graphics presets and individual controls (shadow size,
  anisotropic filtering, film grain, motion blur, depth of field, lens effects).
- Photo mode (F7), free camera (F6), a loop browser and a museum of the game's content, Game+, a speedrun timer with LiveSplit support.
- English, French, German, Spanish, Italian, Portuguese and Japanese from the original, plus Turkish, Simplified Chinese, Arabic, Russian and
  Ukrainian.
- Mods that replace game files, textures and sounds and run Lua scripts: docs/modding.md and docs/lua_api.md. On macOS the folder is
  `~/Library/Application Support/pt-port/pt/mods`.

## What is off on macOS

- Ray-traced shadows, contact shadows, ambient occlusion and reflections: MoltenVK has no ray queries; the renderer uses its fallback.
- FSR, DLSS and XeSS upscaling, frame generation, and VR (OpenXR): Windows only. Apple MetalFX upscaling is available (F10, Upscaler; see docs/upscaling.md).
- Enhanced textures (Real-ESRGAN): there is no macOS build of the tool, so the original textures are used.
- Voice recognition runs on the CPU only.
- No crash dump and no self-update.

## What is different from the original port

Graphics go through MoltenVK (bundled in the app, loaded directly as the Vulkan library). MoltenVK mistypes the lighting pass's G-buffer reads
when a comparison sampler is in the same array, which made floors and walls speckled and rooms dark; macOS builds do that shadow compare by
hand (`PT_SHADOW_MANUAL`). Also macOS-only: a game-folder picker at the first start, helper processes started by the executable's own path,
and a deployment target of macOS 14. The details, with the file-by-file changes, are in [docs/macos.md](docs/macos.md).

## Building from source

    brew install cmake ninja shaderc pkgconf molten-vk vulkan-headers
    cmake -G Ninja -B build/macos-release -DCMAKE_BUILD_TYPE=Release
    cmake --build build/macos-release
    build/macos-release/pt --game <folder>
    python3 tools/macos/package.py        # the signed app bundle, zip and checksums

More, including the tests, in [docs/macos.md](docs/macos.md). Windows and Linux builds, the installer and the upscalers are those of the
[original project](https://github.com/LoreanXavier/pt-pc) and are not the focus here (the code is still in this repository, behind
platform checks). Other docs: docs/upscaling.md, docs/vr.md, docs/updates.md, and the file format notes in docs/formats/.

## Credits and license

The port is by LoreanXavier ([pt-pc](https://github.com/LoreanXavier/pt-pc)) and its own code is under the MIT license (see LICENSE); the
macOS changes here are under the same license. P.T. belongs to Kojima Productions and Konami, and none of its assets are included.

Built on SDL3, zlib, Vulkan (volk, VMA), glm, Dear ImGui, stb, Lua 5.1, libogg and libvorbis, HarfBuzz, bc7enc, whisper.cpp with OpenAI's Whisper
model and the Silero VAD for the voice part, the Noto fonts for the added languages, the ww2ogg codebook library, and, on macOS,
MoltenVK (Khronos Group, Apache-2.0). Their notices ship in the app's `Contents/Resources/licenses/`. The extraction helper downloads
LibOrbisPkg's PkgTool (MIT) at run time. The third-party pieces keep their own licenses.
