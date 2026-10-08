#!/usr/bin/env python3
"""Build the self-contained macOS app bundle (P.T..app) from a Release build and zip it for a GitHub release.

    cmake -G Ninja -B build/macos-release -DCMAKE_BUILD_TYPE=Release && cmake --build build/macos-release
    python3 tools/macos/package.py [--build-dir build/macos-release] [--revision 1] [--app-only]

Output (in dist/macos by default): P.T..app, P.T.-macOS-arm64-<version>.zip, SHA256SUMS.txt, INSTALL-macOS.md.
Nothing from the game is read or included. MoltenVK is the official Khronos release, pinned by version and SHA-256.
"""
import argparse, hashlib, os, plistlib, re, shutil, subprocess, sys, tarfile, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUNDLE_ID = "io.github.x204863x.ptmacos"
MOLTENVK_VERSION = "1.4.2"
MOLTENVK_URL = f"https://github.com/KhronosGroup/MoltenVK/releases/download/v{MOLTENVK_VERSION}/MoltenVK-macos.tar"
MOLTENVK_SHA256 = "f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e"
MOLTENVK_DYLIB = "MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib"
MOLTENVK_LICENSE = "MoltenVK/LICENSE"
DEPLOYMENT_TARGET = "14.0"
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/", "@rpath/", "@loader_path/", "@executable_path/")


def run(*cmd, **kw):
    return subprocess.run([str(c) for c in cmd], check=True, text=True, **kw)


def out(*cmd):
    return subprocess.run([str(c) for c in cmd], check=True, text=True, capture_output=True).stdout


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def project_version():
    m = re.search(r'set\(PT_VERSION "([^"]+)"\)', (ROOT / "CMakeLists.txt").read_text())
    return m.group(1)


def is_macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with open(path, "rb") as f:
        return f.read(4) in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf")


def fetch_moltenvk(cache):
    cache.mkdir(parents=True, exist_ok=True)
    tar = cache / f"MoltenVK-macos-{MOLTENVK_VERSION}.tar"
    if not tar.exists() or sha256(tar) != MOLTENVK_SHA256:
        print(f"downloading {MOLTENVK_URL}")
        urllib.request.urlretrieve(MOLTENVK_URL, tar)
    if sha256(tar) != MOLTENVK_SHA256:
        sys.exit(f"MoltenVK archive checksum mismatch ({sha256(tar)}), refusing to use it")
    extract = cache / f"MoltenVK-{MOLTENVK_VERSION}"
    shutil.rmtree(extract, ignore_errors=True)
    extract.mkdir()
    with tarfile.open(tar) as t:
        for name in (MOLTENVK_DYLIB, MOLTENVK_LICENSE):
            t.extract(name, extract)  # two fixed member names
    return extract / MOLTENVK_DYLIB, extract / MOLTENVK_LICENSE


# Notices of everything linked into the executable (statically) or shipped beside it: name -> (folder under _deps, license file).
# Packaging fails when one is missing, so a dependency can never ship without its notice.
NOTICES = {
    "SDL3-zlib": ("sdl3-src", "LICENSE.txt"),
    "zlib": ("zlib-src", "LICENSE"),
    "volk-MIT": ("volk-src", "LICENSE.md"),
    "VulkanMemoryAllocator-MIT": ("vma-src", "LICENSE.txt"),
    "glm-MIT": ("glm-src", "copying.txt"),
    "DearImGui-MIT": ("imgui-src", "LICENSE.txt"),
    "stb-MIT-or-public-domain": ("stb-src", "LICENSE"),
    "Lua-5.1-MIT": ("lua51-src", "COPYRIGHT"),
    "libogg-BSD-3": ("ogg-src", "COPYING"),
    "libvorbis-BSD-3": ("vorbis-src", "COPYING"),
    "HarfBuzz-MIT": ("harfbuzz-src", "COPYING"),
    "bc7enc": ("bc7enc-src", "LICENSE"),
    "whisper.cpp-MIT": ("whisper-src", "LICENSE"),
}


def copy_notices(build, dest):
    missing = []
    for name, (folder, file) in NOTICES.items():
        src = build / "_deps" / folder / file
        if src.is_file():
            shutil.copy2(src, dest / f"{name}.txt")
        else:
            missing.append(str(src))
    if missing:
        sys.exit("missing third-party license notices (is the build dir complete?):\n  " + "\n  ".join(missing))


def copy_tree(src, dst, keep=lambda p: True):
    for p in sorted(src.rglob("*")):
        rel = p.relative_to(src)
        if p.is_dir() or not keep(rel):
            continue
        (dst / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p.resolve(), dst / rel)  # real copies, never symlinks


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--build-dir", default=str(ROOT / "build/macos-release"))
    ap.add_argument("--out-dir", default=str(ROOT / "dist/macos"))
    ap.add_argument("--revision", default="1", help="macOS release revision: version is <project version>-macos.<revision>")
    ap.add_argument("--app-only", action="store_true", help="only build and sign the .app (no zip, checksums)")
    ap.add_argument("--allow-non-release", action="store_true")
    a = ap.parse_args()

    build = Path(a.build_dir).resolve()
    outdir = Path(a.out_dir).resolve()
    exe = build / "pt"
    if not exe.is_file():
        sys.exit(f"{exe} not found: build the 'pt' target first")
    cache = (build / "CMakeCache.txt").read_text()
    if not a.allow_non_release and "CMAKE_BUILD_TYPE:STRING=Release" not in cache:
        sys.exit("the build dir is not a Release build (use --allow-non-release for a local test bundle)")
    version = project_version()
    release = f"{version}-macos.{a.revision}"

    dylib, mvk_license = fetch_moltenvk(build / "_package_cache")

    app = outdir / "P.T..app"
    shutil.rmtree(app, ignore_errors=True)
    macos, res, fw = app / "Contents/MacOS", app / "Contents/Resources", app / "Contents/Frameworks"
    for d in (macos, res, fw):
        d.mkdir(parents=True)

    shutil.copy2(exe, macos / "pt")
    run("lipo", dylib, "-thin", "arm64", "-output", fw / "libMoltenVK.dylib")  # arm64 slice of the universal release dylib
    copy_tree(build / "shaders", res / "shaders", lambda r: r.suffix == ".spv")
    copy_tree(build / "fonts", res / "fonts")
    copy_tree(build / "voice", res / "voice")
    copy_tree(build / "licenses", res / "licenses")
    copy_notices(build, res / "licenses")
    shutil.copy2(mvk_license, res / "licenses/MoltenVK-Apache-2.0.txt")
    shutil.copy2(ROOT / "LICENSE", res / "licenses/pt-port-LICENSE.txt")
    (res / "licenses/README-MoltenVK.txt").write_text(
        f"libMoltenVK.dylib in Contents/Frameworks is KhronosGroup MoltenVK {MOLTENVK_VERSION} (arm64 slice), Apache-2.0, "
        f"unmodified. Source: https://github.com/KhronosGroup/MoltenVK\n")

    minos = next(l.split()[1] for l in out("vtool", "-show-build", exe).splitlines() if l.strip().startswith("minos"))
    plist = {
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleExecutable": "pt",
        "CFBundleIdentifier": BUNDLE_ID,
        "CFBundleName": "P.T.",
        "CFBundleDisplayName": "P.T.",
        "CFBundlePackageType": "APPL",
        "CFBundleVersion": version,
        "CFBundleShortVersionString": version,
        "LSMinimumSystemVersion": minos,
        "NSHighResolutionCapable": True,
        "LSApplicationCategoryType": "public.app-category.games",
        "NSMicrophoneUsageDescription": "P.T. uses the microphone for one scene (voice recognition).",
        "NSPrincipalClass": "NSApplication",
    }
    with open(app / "Contents/Info.plist", "wb") as f:
        plistlib.dump(plist, f)

    # checks on every Mach-O: deployment target, no dependency outside the system and the bundle
    machos = [p for p in sorted(app.rglob("*")) if is_macho(p)]
    problems = []
    for p in machos:
        mv = [l.split()[1] for l in out("vtool", "-show-build", p).splitlines() if l.strip().startswith("minos")]
        if not mv or any(tuple(map(int, v.split("."))) > tuple(map(int, DEPLOYMENT_TARGET.split("."))) for v in mv):
            problems.append(f"{p.relative_to(app)}: minos {mv}")
        for line in out("otool", "-L", p).splitlines()[1:]:
            dep = line.split()[0] if line.strip() else ""
            if dep and not dep.startswith(SYSTEM_PREFIXES):
                problems.append(f"{p.relative_to(app)}: depends on {dep}")
    if problems:
        sys.exit("bundle check failed:\n  " + "\n  ".join(problems))
    print(f"{len(machos)} Mach-O files, all minos <= {DEPLOYMENT_TARGET}, no external dependencies")

    run("xattr", "-cr", app)
    for p in machos:
        if p != macos / "pt":
            run("codesign", "-s", "-", "--force", p)
    run("codesign", "-s", "-", "--force", "--identifier", BUNDLE_ID, app)
    run("codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
    print(f"built and verified {app}")
    if a.app_only:
        return

    zip_path = outdir / f"P.T.-macOS-arm64-{release}.zip"
    zip_path.unlink(missing_ok=True)
    run("ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", "--noqtn", app, zip_path)
    shutil.copy2(ROOT / "tools/macos/INSTALL-macOS.md", outdir / "INSTALL-macOS.md")
    notes = (ROOT / "tools/macos/release-notes.md.in").read_text().replace("@VERSION@", release).replace("@MOLTENVK@", MOLTENVK_VERSION)
    (outdir / "release-notes.md").write_text(notes)
    (outdir / "SHA256SUMS.txt").write_text(f"{sha256(zip_path)}  {zip_path.name}\n")
    print(f"{zip_path}\n{sha256(zip_path)}")


if __name__ == "__main__":
    main()
