# macOS (Apple silicon)

Native arm64 build, no emulation. Graphics go through Vulkan on MoltenVK (Metal underneath). Tested on an Apple M4 with
macOS 26. The project ships no macOS release; build from source.

## Build

    brew install cmake ninja shaderc molten-vk vulkan-loader vulkan-headers pkgconf
    cmake -G Ninja -B build/macos -DCMAKE_BUILD_TYPE=RelWithDebInfo
    cmake --build build/macos --target pt
    build/macos/pt --game <folder with chunk1.psarc, texture.qar, pathid_list_ps4.bin>

`shaderc` provides `glslc`; the Vulkan loader and MoltenVK are loaded at run time. Settings, saves and `pt.log` live in
`~/Library/Application Support/pt-port/pt/` (SDL's pref path).

## Changes for macOS

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

## App bundle (double-click launch)

`tools/make-macos-app.sh [build_dir] [game_dir] [icon.png]` (writes Info.plist itself; LSMinimumSystemVersion is taken from the binary's minos, 26.0 here) builds `~/Applications/P.T..app` (bundle id `local.ptport.pt`,
`NSMicrophoneUsageDescription` set, category games, ad-hoc signed, no quarantine). No source change was needed:
the window comes to the front when the app is opened with `open` (a Finder double-click was not tested).

    P.T..app/Contents/Info.plist
    P.T..app/Contents/MacOS/pt                  copy of build/macos/pt (a signed bundle needs a regular-file executable)
    P.T..app/Contents/Resources/PT.icns         from ICON0_PNG in PT.pkg (offset 0x183E0, length 0x906A4, 512x512)
    P.T..app/Contents/Resources/{shaders,fonts,voice,bin,licenses}  symlinks into build/macos
    P.T..app/Contents/Resources/pt              copy of the binary: the Museum and Loop Browser previews spawn
                                                 SDL_GetBasePath()/pt (= Resources/pt) as a helper process
    P.T..app/Contents/Resources/game/CUSA01127  symlink to the game folder

`SDL_GetBasePath()` returns `Contents/Resources/` inside a bundle, so shaders, fonts, voice models and
`game/CUSA01127` (found by `FindGameDir`) resolve there. After rebuilding `build/macos`, re-run the script to refresh the
copied binary (resources follow the symlinks). To recreate the icon, extract the PNG with
`dd`/python from the PKG and pass it as the third argument. Info.plist keys: CFBundleExecutable pt, CFBundleIdentifier
local.ptport.pt, CFBundleName P.T., CFBundleIconFile PT, LSMinimumSystemVersion 26.0, NSHighResolutionCapable,
LSApplicationCategoryType public.app-category.games, NSMicrophoneUsageDescription. The Desktop item "P.T." is a symlink
to the app (Finder automation was not permitted, so no Finder alias). The game has no single-instance lock; settings and `pt.log` are shared with a plain `build/macos/pt`.

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

## Degraded or off

- Ray tracing: MoltenVK has no `VK_KHR_acceleration_structure`; the renderer reports "ray queries unavailable" and uses its
  fallback.
- FSR, DLSS, XeSS, frame generation, OpenXR: Windows-only, off (as on Linux).
- Enhanced textures (Real-ESRGAN): no macOS binary, so the option reports missing texture tools and the original textures
  are used. It is off by default.
- Voice (whisper.cpp): works, CPU only (no Metal backend). The `ggml-cpu-apple_m4` variant is chosen on an M4.
- Crash dump and folder picker: none (as on Linux). A plain `build/macos/pt` needs `--game`; the app bundle finds the data itself.
- `tools/walkthrough.py` scenario `voice` needs Windows PowerShell TTS and cannot run; use `pt --voice-test <wav>`.

## Checks

    build/macos/pt --headless --game <folder> --frames 300 --no-save --audio-offline --log out.log
    python3 tools/walkthrough.py early f060 lisa loops --exe $PWD/build/macos/pt --game <folder>

(`--exe` must be an absolute path.) Unit tests build with the rest; `pt_platform_test --network`, `pt_tests`, the
collision, mods, localization, multilingual, save and settings tests pass.

App bundle caveats: the bundle holds copies of the binary (`MacOS/pt` and `Resources/pt`, both written via a temp file and `mv`), so
re-run the script after every rebuild. The symlinks to outside the bundle (`shaders`, `fonts`, `voice`, `bin`, `licenses`, `game/`)
make `codesign --strict` complain ("invalid destination for symbolic link"); the signature is still applied and
`codesign --verify --deep` passes. Only launching through `open` (LaunchServices) was tested, not a Finder double-click or the
microphone prompt.
