# macOS (Apple silicon)

Native arm64 build, no emulation. Graphics go through Vulkan on MoltenVK (Metal underneath). Built for macOS 14 and newer;
tested only on macOS 26 (Apple M4), the macOS 14 and 15 runs are not verified. The release is ad-hoc signed, not notarized.

## Install from a release

Short version, in `INSTALL-macOS.md` (also attached to each release):

1. Unzip `P.T.-macOS-arm64-<version>.zip`, move `P.T..app` to Applications.
2. First start: macOS blocks it (not notarized). Open it once, then System Settings > Privacy & Security > "Open Anyway".
3. Get the game files from your own PT.pkg: `tools/macos/extract-pkg.sh /path/to/PT.pkg` puts `chunk1.psarc`, `texture.qar`
   and `pathid_list_ps4.bin` in `~/Library/Application Support/pt-port/game/CUSA01127`. The helper downloads LibOrbisPkg's
   `PkgTool.Core` (osx-x64 0.2.231, pinned by SHA-256, needs Rosetta), runs `pkg_extract` without a passcode, copies only those
   three files and removes its temporary files. It only reads the PKG. It also applies the game's icon (the PKG's ICON0_PNG entry,
   located through the entry table) to the installed app (`--app <path>`, else /Applications or ~/Applications; `--no-icon`,
   `--icon-only`), converting it to PT.icns locally and re-signing ad hoc; the release itself carries no icon. Nothing from the game is in this repository or the release.
4. Start the app. Where it looks for the game, in order: `--game <folder>`; `game/CUSA01127` or `CUSA01127` next to the app
   (up to five folders up); `~/Library/Application Support/pt-port/game/CUSA01127`; the folder remembered in
   `~/Library/Application Support/pt-port/pt/game_dir.txt`. If none is found, a folder dialog opens; the folder must hold the
   three files (otherwise a message and the dialog again); the choice is saved in `game_dir.txt`. Cancel closes the game with the
   "files not found" message. Pass `--game` to override everything.

Settings (`pt.ini`), saves, `game_dir.txt` and `pt.log` live in `~/Library/Application Support/pt-port/pt/`. Mods go in
`~/Library/Application Support/pt-port/pt/mods/` (see docs/modding.md; the folder next to the program is not used on macOS).
The microphone prompt (voice recognition scene) appears when that is first used.

## Build from source

    brew install cmake ninja shaderc pkgconf molten-vk vulkan-headers
    cmake -G Ninja -B build/macos-release -DCMAKE_BUILD_TYPE=Release
    cmake --build build/macos-release
    build/macos-release/pt --game <folder>

`shaderc` provides `glslc`. CMake sets `CMAKE_OSX_DEPLOYMENT_TARGET` 14.0 and arm64 (the cache values can be changed, but only 14.0
is tested). Homebrew's MoltenVK is used by a plain `build/.../pt` (development); the app bundle carries its own.

### Package the app bundle

    python3 tools/macos/package.py [--build-dir build/macos-release] [--revision 1]

Writes `dist/macos/`: `P.T..app`, `P.T.-macOS-arm64-<project version>-macos.<revision>.zip` (made with `ditto -c -k --keepParent`),
`SHA256SUMS.txt`, `INSTALL-macOS.md`. `--app-only` stops after the signed app (use `--allow-non-release` with a RelWithDebInfo build).
Layout (real files, no symlinks):

    P.T..app/Contents/Info.plist              bundle id io.github.x204863x.ptmacos, microphone usage text, games category,
                                              LSMinimumSystemVersion from the binary (14.0), high-res capable
    P.T..app/Contents/MacOS/pt                the game (also the preview helper process: it is started by its own path)
    P.T..app/Contents/Frameworks/libMoltenVK.dylib   MoltenVK 1.4.2, official Khronos release, arm64 slice, pinned by version + SHA-256
    P.T..app/Contents/Resources/{shaders,fonts,voice,licenses}   SPIR-V, fonts, whisper runtime and models, licenses
                                              (including MoltenVK's Apache-2.0 text, this project's MIT license, and the license of every statically linked or bundled dependency: SDL3, zlib, volk, VMA, glm, Dear ImGui, stb, Lua, libogg, libvorbis, HarfBuzz, bc7enc, whisper.cpp, the ww2ogg codebook library; `package.py` fails if one is missing)

The script refuses a non-Release build, checks that every Mach-O has minos <= 14.0 and depends only on system libraries or the bundle,
signs the libraries and the bundle ad hoc, and runs `codesign --verify --deep --strict`. There is no icon (the default one): an icon
would have to come from the game's assets, which this project does not redistribute. You can add your own to your local copy.

### How Vulkan is loaded

macOS has no system Vulkan loader. SDL and volk can use `libMoltenVK.dylib` directly (it exports `vkGetInstanceProcAddr`), so the
bundle does not ship the Khronos loader. `MacVulkanLibrary()` (`src/engine/render/vk_context.cpp`) tries, in order: `PT_VULKAN_LIBRARY`;
`Contents/Frameworks/libMoltenVK.dylib`; `libMoltenVK.dylib` / `libvulkan.1.dylib` next to the executable; Homebrew's
`libvulkan.1.dylib`, then `libMoltenVK.dylib` (`/opt/homebrew`, `/usr/local`). The chosen file is logged as `vulkan: loader <path>`.
`SDL_Vulkan_LoadLibrary` gets the same path before the window is created.

## What is different or off on macOS

- Ray tracing: MoltenVK has no `VK_KHR_acceleration_structure`; the renderer reports "ray queries unavailable" and uses its fallback.
- FSR, DLSS, XeSS, frame generation, OpenXR: Windows-only, off (as on Linux).
- Enhanced textures (Real-ESRGAN): no macOS binary; the option reports missing tools and the original textures are used.
- Voice (whisper.cpp): works, CPU only (no Metal backend); the matching `ggml-cpu-apple_*` variant is chosen for the CPU.
- No crash dump. No Windows installer; no self-update (the update check only reports a newer macOS release).
- `tools/walkthrough.py` scenario `voice` needs Windows PowerShell TTS and cannot run; use `pt --voice-test <wav>`.
- Not tested: a Finder double-click on a fresh Mac with Gatekeeper, the microphone prompt, macOS 14/15, Intel Macs (not supported).
- If the game-folder dialog is open, quitting the app (Cmd-Q, SIGTERM) does not close it; use Cancel in the dialog.

## Source changes for macOS

Everything is behind `__APPLE__` / `if(APPLE)`; Windows and Linux are unchanged except where noted.

| File | Change |
|---|---|
| `src/engine/render/vk_context.{h,cpp}` | `MacVulkanLibrary()` finds the loader by path (`PT_VULKAN_LIBRARY`, beside the exe, `/opt/homebrew/lib`, `/usr/local/lib`, then MoltenVK itself) because volk and SDL only search system paths, which excludes Homebrew and is not set up for Finder launches. The instance enables `VK_KHR_portability_enumeration` with `VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR`; the device enables `VK_KHR_portability_subset` when offered. |
| `src/main.cpp` | `SDL_Vulkan_LoadLibrary` with that path before `SDL_CreateWindow` (otherwise "Failed to load Vulkan Portability library"). |
| `src/engine/audio/sound_engine.cpp` | flush-to-zero on the render thread used x86 `_mm_setcsr`; arm64 sets FPCR.FZ instead. |
| `src/engine/platform/http.cpp` | libcurl is dlopened as `libcurl.4.dylib` (system copy in `/usr/lib`). |
| `src/engine/platform/update_check.cpp` | platform string `macos` instead of `linux`, so a Linux release is never offered. |
| `src/engine/voice/voice_recognizer.cpp` | `.dylib` for whisper/ggml, `.so` for ggml's CPU backend modules (CMake names modules `.so` on macOS), thread priority through a QoS class (`SYS_gettid` is not Linux's on macOS). |
| `src/engine/assets/enhanced_textures.cpp` | cast `file_time_type` count (a `__int128` in libc++) to `long long` before streaming it. |
| `src/engine/ui/unicode_font_harfbuzz.cpp` | the HarfBuzz (non-Windows) font table lacked "Noto Kufi Arabic"/"Noto Naskh Arabic", the faces the engine asks for; Arabic failed in `pt_multilingual_test`. Also affects Linux. |
| `cmake/Dependencies.cmake` | `GGML_METAL=OFF` (needs the Objective-C language, which the project does not enable; CPU + Accelerate is used); `@loader_path` rpath for the voice libraries; the Apple CPU variants (`apple_m1`, `apple_m2_m3`, `apple_m4`) join the `pt_voice_runtime` set. |
| `shaders/lighting.glsl`, `CMakeLists.txt` | `-DPT_SHADOW_MANUAL` on Apple: manual shadow compare, see "Lighting fix" below. |
| `cmake/EnhancedTextures.cmake` | on Apple do not download the Linux Real-ESRGAN build. |
| `src/engine/core/resource_path.{h,cpp}` | `SelfExecutablePath()` (`_NSGetExecutablePath`): the museum and loop preview helper processes are started by the executable's own path, because `SDL_GetBasePath()` is `Contents/Resources` in a bundle. |
| `src/main.cpp` | `FindGameDir`: `~/Library/Application Support/pt-port/game/CUSA01127` and an SDL folder dialog; mods read from the user data folder. |
| `src/engine/anim/anim_test.cpp` | floating-point `std::from_chars` needs macOS 26's libc++; `strtod` is used on Apple (deployment target 14). |
| `src/engine/core/resource_path.cpp` (all platforms) | intentional behaviour change on Windows/Linux: the helper process path is now built with `ExecutableDir() / "pt(.exe)"` inside `SelfExecutablePath()` where `main.cpp` used `std::filesystem::path(SDL_GetBasePath()) / ...`; the base path is now converted as UTF-8 (`ExecutableDir()`), so non-ASCII install folders work for the previews. |
| `CMakeLists.txt` | deployment target 14.0, arm64. |

Related prior work (MIT): the upstream pull request LoreanXavier/pt-pc#4 and the `macos-arm64-preview-2` branch of ignusloki/pt-pc. This implementation was written independently; no code was copied from them.

## Lighting fix: speckled floors and walls, dark rooms

Symptom on macOS (not on Windows): the intro room floor was a dark, high-contrast speckle (the carpet-like grit also on walls), rooms
looked dark and blotchy, and the ceiling lamp globe was a small blue-white speck. Cause, found by dumping render targets
(`PT_TARGET_DUMP=1` with a scripted `shot`) and probing the light pass:

- In `shaders/lighting.glsl` the shadow atlas is read with a comparison sampler, `sampler2DShadow(images[IMG_SHADOW], ...)`, while the
  rest of the lighting shader fetches the G-buffer through the same `images[]` array. MoltenVK (SPIRV-Cross, Metal) then types the
  whole `images[]` array as depth textures, so every plain fetch from it in that shader returns the red channel in all four
  components. In the light pass the normal (x, y, z), roughness/specular/material index and translucency were all read as one value
  (probe: normal `(0.502, 0.502, 0.502)` where the dump holds `(0.502, 0.969, 0.577)`). Decoded normals were garbage, so the diffuse
  term of the main light varied with a coefficient of variation of 0.9 on a flat floor. Probes: the same fetch in a minimal shader is
  correct; with the shadow tap removed from the light shader it is correct; the debug view (no shadow sampler) is correct. No
  validation message is produced.
- `MVK_CONFIG_FULL_IMAGE_VIEW_SWIZZLE=1`, `MVK_CONFIG_FAST_MATH_ENABLED=0`, turning shadows off at run time, anisotropy and the
  texture settings do not change it (the shadow code is still compiled in).

Fix (macOS only): `CMakeLists.txt` passes `-DPT_SHADOW_MANUAL` to glslc on Apple, and `ShadowTap` in `shaders/lighting.glsl` then does
the compare by hand (four `texelFetch`es, `ref < depth`, bilinear weights, clamp to edge: what the LESS/linear/clamp sampler does).
Other platforms keep the hardware sampler. Result for the opening room (`--start-floor f000`, frame 3300): floor diffuse mean
0.167 -> 0.275 with coefficient of variation 0.89 -> 0.11, smooth grey concrete floor and evenly lit plaster; the hallway frames of the
walkthrough gain wall and ceiling light, a visible ceiling and the lamp globe (mean image brightness changes by only about +1 to +3
of 255; the scenes are dark by design).

Not verified on a second Vulkan driver (no Mesa/lavapipe on macOS); the conclusion rests on the probes above. The hard diagonal
shadow on the ajar door is a real shadow of the light above (`shadow_quality = 0` removes it); it was not changed.
`graphics.texture_detail` is a mip bias on every material texture sample (+1 reduced, 0 original, -0.5 fine).
`pt_reflection_mix_test` fails one case ("blend both reflection sources": the shader computes (0.667, 0.333, 0, 0.3), the test expects
(0.8, 0.2, 0, 0.5)); it fails the same before and after, and was not checked on another platform.

## Testing the first-start folder dialog

`tools/macos/test-folder-dialog.sh run` hides `game_dir.txt` and renames the default data folder (`pt-port/game` to `pt-port/game.moved-by-dialog-test`) for one launch of `dist/macos/P.T..app`, waits
for the app to quit, then restores both (`pt.log` is kept as evidence in `~/Library/Application Support/pt-port/.dialog-test-backup/last-run.log`). Saves, settings and your
own game folder are never moved. Steps: (1) run it, an information box appears: OK; the folder dialog opens; choose a wrong folder (e.g.
Documents): expect an error box and the dialog again. (2) Choose the folder with the three game files: the game starts; quit it.
`report` then shows the `game_dir.txt` it would have written and the log lines. (3) Run it again and press Cancel: expect the
"game files were not found" box (macOS wording, pointing to INSTALL-macOS.md) and the app exits. If a run is interrupted, run `restore`.

## Where tests write

`--headless` never writes saves, and `tools/walkthrough.py` passes `--no-save` (or `--save-dir <work folder>` for the scenarios that need a save) and runs in a
temporary work folder with its own log and settings, so neither touches `~/Library/Application Support/pt-port/pt/`. A normal (windowed)
launch does: `pt.ini`, `pt.log` and the save slots go there, also in a test launch. For tests that open a window,
pass `--no-save --settings <temp>/pt.ini --log <temp>/pt.log`. `pt_save_*_test` take a not-yet-existing scratch folder.

## Checks

    python3 -I tools/walkthrough.py early f060 lisa loops --exe <abs path>/P.T..app/Contents/MacOS/pt --game <folder>

(`--exe` must be an absolute path.) Unit tests build with the rest; `pt_tests`, collision, mods, platform, graphics preset, language default,
localization, multilingual, save reset/status and settings round-trip pass (some take the game folder or a not-yet-existing scratch folder as
argument, see the sources). `pt_reflection_mix_test` fails one case ("blend both reflection sources"); it failed before this work and was not
checked on another platform.
