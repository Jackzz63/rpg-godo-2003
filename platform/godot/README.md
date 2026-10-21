# Patched Godot 4.7.2 client templates

Two patches form part of the client source:

| Patch | Platforms | Purpose |
| --- | --- | --- |
| [4.7.2-lineedit-shadow.patch](patches/4.7.2-lineedit-shadow.patch) | Windows / Android | Native LineEdit glyph shadows, enabled explicitly by the chat theme |
| [4.7.2-android-surface-lifecycle.patch](patches/4.7.2-android-surface-lifecycle.patch) | Android | Preserve an intermediate Surface loss while the GL thread is initializing |

The official editor remains unchanged. Linux currently uses the official export
template. Windows and Android exports requiring the current client behavior
must use the patched templates described below.

## Source and toolchain

Use [Godot 4.7.2-stable source](https://github.com/godotengine/godot/tree/4.7.2-stable)
and the matching official editor/export-template bundle. Keep the Godot source
and build directories outside this application source tree. No second full
Godot checkout or compiled templates are included here.

The local builds used these inputs; public CI validation is still a separate step:

- Godot source archive: `https://codeload.github.com/godotengine/godot/zip/refs/tags/4.7.2-stable`.
- Recorded source archive SHA-256: `f0c95e750cb5f2a75c9ba54103722b241b185c4ea92c15d914575da95a1b3cf0`.
- Python with `SCons==4.10.1`.
- Windows: MSVC 14.5, Windows SDK 10.0.26100, Mesa static 25.3.1-3,
  ANGLE chromium/7219, Agility SDK 1.618.5 and AccessKit C 0.22.3.
- Android Godot native engine: NDK 29.0.14206865, ARM64, Swappy
  `from-source-2025-01-31` under `thirdparty/swappy-frame-pacing`.
- Android Godot Java AAR: SDK 36, Build Tools 36.1.0, Java 17 or later
  with bytecode target 17.
- Official base `android_source.zip` recorded SHA-256:
  `a15416b528efb0a19a7d187e4d9f4e5336d0689144b111329fb4bd12c4447ad3`.

The Java/engine build toolchain is distinct from the final application's SDK
30/35 and NDK 28.1 packaging/strip settings. Prepare the pinned platform build
dependencies required by this Godot source version before invoking SCons.

## Windows template

Use a separate clean Godot source copy and an x64 Visual Studio developer shell.
Set `RPGGODO_SOURCE` to this application's source directory, then run from the
Godot source root:

```powershell
git apply --check "$env:RPGGODO_SOURCE/platform/godot/patches/4.7.2-lineedit-shadow.patch"
git apply "$env:RPGGODO_SOURCE/platform/godot/patches/4.7.2-lineedit-shadow.patch"
$env:BUILD_NAME = 'rpggodo_lineedit_shadow'
python -m SCons platform=windows target=template_release production=yes debug_symbols=no arch=x86_64 angle=yes d3d12=yes accesskit=yes -j8
```

Install the following files under the editor's `export_templates/4.7.2.stable/`:

| Built file under Godot `bin/` | Installed template name |
| --- | --- |
| `godot.windows.template_release.x86_64.exe` | `windows_release_x86_64.exe` |
| `godot.windows.template_release.x86_64.console.exe` | `windows_release_x86_64_console.exe` |

Keep the matching official `version.txt` (`4.7.2.stable`) and the generated
D3D12 support DLLs with the template bundle when present. Use the matching
official `linux_release.x86_64` for Linux exports.

## Android native libraries and patched Java AAR

Use another clean Godot source copy. Set `ANDROID_HOME` / `ANDROID_SDK_ROOT` to
the SDK containing the engine's NDK and Java build tools, and set `JAVA_HOME`.
Run from the Godot source root:

```powershell
git apply --check "$env:RPGGODO_SOURCE/platform/godot/patches/4.7.2-lineedit-shadow.patch"
git apply "$env:RPGGODO_SOURCE/platform/godot/patches/4.7.2-lineedit-shadow.patch"
git apply --check "$env:RPGGODO_SOURCE/platform/godot/patches/4.7.2-android-surface-lifecycle.patch"
git apply "$env:RPGGODO_SOURCE/platform/godot/patches/4.7.2-android-surface-lifecycle.patch"
$env:BUILD_NAME = 'rpggodo_lineedit_shadow'
python -m SCons platform=android target=template_release production=yes debug_symbols=no arch=arm64 generate_android_binaries=no -j8
Set-Location platform/android/java
./gradlew.bat :lib:assembleTemplateRelease -x :lib:compileGodotNativeLibsTemplateReleaseArm64 -PdoNotStrip=true --no-daemon --max-workers=4 --console=plain
```

On a Linux build host, use the equivalent environment assignments and `./gradlew`.
Ensure SCons is available on `PATH` for the Java build. Do not run Gradle `clean`
between these steps: it removes the native libraries produced above.

Required outputs relative to the Godot source root:

- `platform/android/java/lib/libs/release/arm64-v8a/libgodot_android.so`.
- `platform/android/java/lib/libs/release/arm64-v8a/libc++_shared.so`.
- `platform/android/java/lib/build/outputs/aar/godot-lib.template_release.aar`.

The new AAR contains the Surface lifecycle fix. A stock AAR with only native
SO replacement does **not** contain that fix.

## Assemble the Android source template

Use Python's standard `zipfile` module (or an equivalent ZIP tool) to replace:

1. `jni/arm64-v8a/libgodot_android.so` and `jni/arm64-v8a/libc++_shared.so`
   inside the **rebuilt Java AAR**, using the matching native outputs above.
2. `libs/release/godot-lib.template_release.aar` inside a fresh copy of the
   official `android_source.zip`, using that AAR.

The following Python recipe performs those two replacements without keeping
the old official Java implementation. Set the three environment variables to
absolute paths before running it:

```python
import io
import os
from pathlib import Path
import zipfile

godot = Path(os.environ['GODOT_SOURCE'])
official = Path(os.environ['GODOT_OFFICIAL_TEMPLATES'])
output = Path(os.environ['GODOT_PATCHED_TEMPLATES'])
output.mkdir(parents=True, exist_ok=True)

def replace_entries(data, replacements):
    target = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(data)) as src:
        missing = replacements.keys() - set(src.namelist())
        if missing:
            raise RuntimeError(f'Missing template entries: {sorted(missing)}')
        with zipfile.ZipFile(target, 'w') as dst:
            for item in src.infolist():
                dst.writestr(item, replacements.get(item.filename, src.read(item)))
    return target.getvalue()

java = godot / 'platform/android/java/lib'
native = java / 'libs/release/arm64-v8a'
aar = (java / 'build/outputs/aar/godot-lib.template_release.aar').read_bytes()
aar = replace_entries(aar, {
    f'jni/arm64-v8a/{name}': (native / name).read_bytes()
    for name in ('libgodot_android.so', 'libc++_shared.so')
})
template = replace_entries((official / 'android_source.zip').read_bytes(), {
    'libs/release/godot-lib.template_release.aar': aar
})
(output / 'android_source.zip').write_bytes(template)
for name in ('version.txt', 'android_release.apk'):
    (output / name).write_bytes((official / name).read_bytes())
```

Use the resulting source ZIP for a **Gradle** export. The copied stock
`android_release.apk` is only a companion template input and does not by itself
contain these patches. It must not be used as a non-Gradle release substitute.
Continue with [Android plugin integration and export](../android/native-input/README.md).

## Patch behavior

The LineEdit patch adds `shadow_enabled`, `font_shadow_color`, `shadow_offset_x`
and `shadow_offset_y` theme items. Only the chat LineEdit opts into the new glyph
pass. The pass reuses shaped text and preserves caret, selection and IME logic.

The Android patch latches an intermediate Surface loss under the existing GL
thread monitor and consumes it through the existing EGLSurface cleanup path.
It does not block the Android UI thread or recreate the Activity/EGLContext.
