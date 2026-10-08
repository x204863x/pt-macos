# Upscaling and frame generation

The original renders at 1920x1080 with FXAA. The port can render the scene at a lower internal resolution and
reconstruct the output with a temporal upscaler (AMD FSR 3.1, NVIDIA DLSS 4.5, Intel XeSS, on macOS Apple MetalFX), or keep the display
resolution and use the upscaler as anti-aliasing (FSR native AA, DLAA, MetalFX at ratio 1). Everything here is off by default; with the
upscaler off the frame is the same as without this feature.

## Settings

`pt.ini`, section `[upscaling]`, and the Upscaling rows of the PC settings page (F10):

| key | values | meaning |
| --- | --- | --- |
| `upscaler` | `off`, `fsr3`, `fsr4`, `dlss`, `xess`, `metalfx` | backend. The page lists every backend and greys the ones this machine or build cannot run, with the reason on the help line |
| `quality` | `native`, `quality`, `balanced`, `performance`, `ultra_performance`, `custom` | render scale 1/1.0, 1/1.5, 1/1.7, 1/2.0, 1/3.0 per axis (the FSR ratios, used for every backend), or `scale` |
| `scale` | 0.25 to 1.0 | render scale per axis for `custom` |
| `sharpness` | 0 to 1 | FSR: RCAS after the upscaler. DLSS and MetalFX have no sharpening |
| `dlss_model` | `auto`, `k`, `l`, `m` | the DLSS Super Resolution model. `auto` is NVIDIA's default per quality (K for DLAA, quality and balanced, M for performance, L for ultra performance). L and M run in FP8, which RTX 20 and 30 cards lack, so they cost about twice as much there |
| `frame_generation` | `off`, `fsr3`, `dlss` | one generated frame between two rendered frames. Needs a window and an upscaler (any backend and quality) |

## What the port does per frame

With an upscaler active the render extent is `output / ratio`, the projection is jittered with the Halton(2,3)
sequence, and material textures are sampled with a mip bias of `log2(render / output)` so the mips are those of a
native frame. The scene passes (G-buffer, SSAO, lighting, forward, effects, reflections) run at the render extent.
Then:

- a reactive mask is written from what the effects pass blended over the opaque scene (particles, glass, blood);
- motion vectors are drawn for the whole frame, and again for objects whose transform or skin changed;
- the flashlight's contribution is divided out of the colour the upscaler sees and multiplied back in after it.
  Without this, the spot moving over still surfaces (whose motion vectors are those of the surface) left dark echo
  rings in the upscaler's history;
- the two fixed per-pixel patterns the original draws (the 8x8 Bayer dither of alpha-tested hair and the 2x2 offset of
  the shadow taps) are cycled frame by frame, because a temporal upscaler keeps a fixed pattern as texture. The history
  averages them into the coverage they stand for;
- the backend writes an output-sized image; the post chain (bloom, tonemap, depth of field, motion blur, colour LUT,
  grain) runs at the output resolution as before. FXAA is skipped: the upscaler is the anti-aliasing.

A camera cut or a missing previous frame resets the upscaler history.

## Backends

### AMD FSR 3.1

FidelityFX SDK 1.1.4 through the FidelityFX API, using AMD's signed `amd_fidelityfx_vk.dll` (MIT),
loaded at run time from the executable's folder; without the DLL FSR is unavailable. Sharpness drives RCAS.

### AMD FSR 4

listed and greyed. AMD has released FSR 4 for DirectX 12 only; the newest FidelityFX release with a
Vulkan backend is 1.1.4, which has no FSR 4 provider. The row looks for a `4.x` upscaler provider in
`amd_fidelityfx_vk.dll`, so a later Vulkan DLL from AMD that carries one would be picked up. A `pt.ini` with
`upscaler = fsr4` renders without an upscaler until then.

### NVIDIA DLSS

DLSS SDK 310.9.1, `nvngx_dlss.dll` next to `pt.exe`. The qualities map to DLAA, MaxQuality, Balanced,
MaxPerf and UltraPerformance. NGX is loaded only once DLSS is selected; loading it starts the driver's `nvngx_update.exe`,
the model updater every DLSS game starts. DLSS computes its own exposure, which handles P.T.'s dark frames better than the
frame's exposure value. If the driver asks for Vulkan extensions the device was not created with, selecting DLSS reports
that a restart is needed.

### Intel XeSS

XeSS SDK 3.0.2, `libxess.dll` next to `pt.exe`, loaded when XeSS is selected. GPUs other than Intel Arc
run its DP4a model. The qualities use the XeSS preset with the same ratio; `custom` takes the nearest.

### Apple MetalFX

macOS only (`upscaler = metalfx`), the `MTLFXTemporalScaler` from the system's MetalFX framework; nothing to download. It is greyed
with the reason where the build is not for macOS, MoltenVK lacks `VK_EXT_metal_objects`, or `supportsDevice:` is false. All
qualities work, native AA is a ratio of 1. The GPU's supported ratio range (`supportedInputContentMin/MaxScaleForDevice`, 1.0 to 3.0
on an M4) limits the render size: `custom` below 33% renders at 33%, and the F10 help line and `pt.log` say so. There is no sharpening.

Interop: `VK_EXT_metal_objects` exports the MTLDevice and the MTLTexture behind each Vulkan image. MetalFX encodes into a
Metal command buffer, so with it active the frame is two Vulkan submits instead of one. The first ends at the upscale and signals a
timeline semaphore; the backend commits a Metal command buffer on its own queue that waits for that value (the semaphore is exported as an
MTLSharedEvent), runs the scaler and signals the next value; the second submit waits for it. The swapchain acquire wait, the present
signal and the frame fence stay on the second submit. The backend proves both directions of the event when it is first offered. If the first submit
fails, the Metal work is skipped and the host signals the semaphore, so the second submit and the frame fence still complete (all of that
submit's work is dropped, so that frame shows stale content). Under `--validation` or `PT_METALFX_HOST_SYNC` the CPU waits for the Metal
work every frame and signals the semaphore from the host, because the validation layer cannot see Metal's signal and reports the
present as unresolved.

Conventions: depth is reversed (`depthReversed`), the motion vectors (previous minus current, in render-size fractions) are scaled by
the render size, the reactive mask is used (macOS 14.4 and newer, else skipped), and the exposure is a 1x1 R16F texture holding the
exposure value, clamped to the half-float range (the scene colour is not pre-multiplied, so `preExposure` stays 1). Jitter: the pixel offset of the projection, x right and y down, passed unchanged; of the four sign
combinations on a static pose against a 4x supersampled frame, (+x, +y) was best (33.48 dB, least shimmer; wrong x worse than none).
The images the upscaler reads and writes are in `GENERAL` layout
across the Metal work and go back to shader-read after it. The Vulkan images that are exported carry `VkExportMetalObjectCreateInfoEXT`
(and the instance the device one), as `VK_EXT_metal_objects` asks. On macOS the output image also has the colour attachment usage
MetalFX asks for.

Cost, measured on an M4 at 2560x1440, quality (1707x960 inside), 400 frames of a lit scene, GPU time a frame: native 28.5 ms; with the
`spatial` test upscaler, which runs the same motion, reactive and resolve passes but no scaler, 19.1 ms (those passes 0.9 ms);
MetalFX 24.9 ms. So MetalFX itself costs about 5.7 ms there: its Metal command buffer spans 6.2 ms on the GPU, which includes
waiting for the Vulkan work before it and is not the scaler's own cost (4.3 ms at performance, 7.5 ms at native AA), and the reactive mask is 0.4 to 1.2 ms of that. The split of the
submit is cheap: an empty Metal command buffer between the two submits adds 0.2 to 0.5 ms. Rendering at 1707x960 saves about 9.4 ms (native minus the spatial run),
so quality is about 3.6 ms faster than native here, and slower than a bilinear upscale by the scaler's cost. `pt.log` has the average
time of the Metal command buffer at exit.

The three SDKs are Windows binaries, so the upscalers are left out of the Linux build (docs/linux.md).

## Frame generation

### FSR 3

AMD FSR 3.1 frame generation from the same DLL, with the Vulkan frame interpolation swapchain. It needs an
active upscaler (FSR, DLSS or XeSS; the interpolation reads the upscaler's depth and motion vectors). While it is on the
swapchain presents with v-sync whatever the v-sync setting: with v-sync off the driver's present call blocked within
seconds in every test run here. Each rendered frame and its generated frame take whole refreshes, so a frame that does
not fit two refreshes takes three; at 2560x1440 DLAA on a 260 Hz display this showed 176 frames a second but rendered 88
instead of 162. The UI is drawn into the rendered frames only and is not interpolated. AMD lists the Radeon RX 5000
series as the minimum, and the port checks for it: on a GCN card (RX 400 and 500, Vega) the row is greyed, and a
`pt.ini` asking for it renders without. A tester's RX 580 lost the Vulkan device repeatedly with it on.

### DLSS Frame Generation

through NVIDIA Streamline 2.14.1. It needs a GeForce RTX 40 or newer, a driver with DLSS
Frame Generation, and hardware-accelerated GPU scheduling turned on in Windows graphics settings; the row names which
of these is missing. It is experimental: I have no RTX 40 or 50, so the generated frames themselves have never run on
hardware here. Streamline loads only for a start whose `pt.ini` has `frame_generation = dlss` and a window; choosing
DLSS in the menu takes effect at the next start. If a start with Streamline crashes or hangs, the next start leaves it
out, sets `frame_generation = off` and greys the row for that session. On Vulkan Streamline cannot present with
v-sync, so the swapchain runs without it while frame generation is on, and the fps limit goes to Reflex's frame
limiter. In menus and the paused game frame generation is off. A build configured with `-DPT_STREAMLINE=OFF` leaves the
code and the DLLs out. Not covered: the UI alpha tag (the HUD-less copy alone separates the UI), the distortion field,
multi frame generation (RTX 50).

If you have an RTX 40 or 50: set `frame_generation = dlss` with DLSS or FSR in `pt.ini`, start in a window, and check
`pt.log` for `streamline: DLSS ok, DLSS Frame Generation ok` and the summary `presented N frames for M rendered` at
exit (N about 2 M). The Streamline log is `streamline/sl.log` next to `pt.ini`. An issue with that log is welcome
either way.

Licences in `licenses/` next to `pt.exe`: Streamline's (MIT), the NVIDIA RTX SDKs licence (DLSS and `nvngx_dlssg.dll`)
and Reflex's. Only the signed production DLLs ship.

## DLSS 5

DLSS 5 neural rendering is not in the port. NVIDIA's public SDKs (DLSS 310.9.1, Streamline 2.14.1) carry no plugin,
header or runtime for it, and the community route runs through an unsigned DLL taken from a game, which the NVIDIA RTX
SDKs licence forbids using. If NVIDIA publishes it for Vulkan, the port has the inputs it takes (the tonemapped frame
before the UI, depth, motion vectors, the G-buffer).

## What to expect

Measured on an RTX 3090 at fixed poses against a 4x supersampled render: DLAA and DLSS quality score at or above the
native frame on still views, the other modes come within 1 to 4 dB of it (the lower the render resolution, the
further), and all three upscalers follow thin geometry in motion (window mullions, picture frames) more steadily than
the original's FXAA. GPU time at 1920x1080 in the corridor, native with
FXAA 3.1 ms: FSR quality 2.7 ms, DLSS quality 3.0 ms, XeSS quality 3.2 ms; at 3840x2160, native 10.3 ms against 7.7, 8.5
and 8.2 ms. The native AA modes cost 0.8 to 1.1 ms more than native at 1080p. On RTX 20 and 30 the DLSS models M and L
cost about twice K, so DLSS performance can take more GPU time than DLSS quality there.

Known differences: under FSR the wet asphalt of the ending street comes out a few levels darker under the flashlight
(its accumulation loses some of the sparkle); the eye adaptation is a little behind native for the first second after
a cut in every mode.

## DLSS Frame Generation on RTX 20 and 30

DLSS Frame Generation needs an RTX 40 or newer card. On an RTX 20 or 30 the row is greyed out, unless RTX30MFG-Unlock
(github.com/mcsoderh/RTX30MFG-Unlock) sits next to pt.exe: `RTX40MFGCore.dll`, `RTX40MFG.asi` and the Ultimate ASI Loader as
`version.dll` with its `global.ini` values in `version.ini`. The game then lets Streamline decide, and Streamline accepts the
card. Tested once on an RTX 3090: it generates frames. It is third-party and experimental; nothing of it ships with the game.
