# Android native build, input plugin and export

This directory contains the Java input plugin and its Manifest registration.
The matching Godot runtime scripts and assets are in `demo/platform/android/`.
The app's checked-in export preset is named **Android P3** and selects ARM64.

## Build the EasyRPG bridge

Use NDK **28.1.13356709**, native API **28**, C++ shared runtime, and vcpkg's
`arm64-android` target. The native API is separate from the app's min SDK 30.
For example, from the application repository root in a Windows build shell:

```powershell
# VCPKG_ROOT and ANDROID_HOME must point to installed toolchains.
$ndk = "$env:ANDROID_HOME/ndk/28.1.13356709"
cmake -S . -B build-android-release -G Ninja `
  "-DCMAKE_TOOLCHAIN_FILE=$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" `
  "-DVCPKG_CHAINLOAD_TOOLCHAIN_FILE=$ndk/build/cmake/android.toolchain.cmake" `
  -DVCPKG_TARGET_TRIPLET=arm64-android `
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 -DANDROID_STL=c++_shared `
  -DCMAKE_BUILD_TYPE=Release -DGODOTCPP_TARGET=template_release `
  -DPLAYER_ENABLE_TESTS=OFF -DLIBLCF_ENABLE_TESTS=OFF -DLIBLCF_ENABLE_BENCHMARKS=OFF
cmake --build build-android-release --target easyrpg_godot --parallel
```

This builds `demo/bin/libeasyrpg_godot_arm64.so`. For a Debug native library use
a separate build directory, `CMAKE_BUILD_TYPE=Debug` and
`GODOTCPP_TARGET=template_debug`; the descriptor selects
`libeasyrpg_godotd_arm64.so`. Android presets must not be changed to select that
Debug output for a Release export.

If exporting from Windows, also build the Windows bridge for the official
Windows editor's import step. See the [root build instructions](../../../README.md).

## Prepare the final Android project

First build the [patched Godot native libraries and Java AAR](../../godot/README.md).
Copy `demo/` into a **fresh** staging project and disable only the staged
`[editor_plugins]` hooks as described in the root README. Keep the runtime addons.

Extract the patched `android_source.zip` directly into
`<staged-project>/android/build/`. Write `4.7.2.stable` to
`<staged-project>/android/.build_version` and create an empty
`<staged-project>/android/build/.gdignore`.

The final application build keeps the following `android/build/config.gradle`
settings (distinct from the engine Java AAR build):

| Setting | Official 4.7.2 value | Application export value |
| --- | --- | --- |
| `compileSdk` | 36 | 35 |
| `targetSdk` | 36 | 35 |
| `buildTools` | `36.1.0` | `35.0.1` |
| `ndkVersion` | `29.0.14206865` | `28.1.13356709` |

Copy every `.java` file in `src/main/java/org/rpggodo/android/` to
`<staged-project>/android/build/src/main/java/org/rpggodo/android/`.
Insert the contents of [AndroidManifest.fragment.xml](AndroidManifest.fragment.xml)
inside the `<application>` element of the staged
`android/build/src/main/AndroidManifest.xml`, immediately before its closing tag.
Do this once in a fresh stage, not cumulatively over an old Manifest.

The three Java classes must be included together: `NativeTextInputPlugin`,
`ChatEditJournal` and `DisplayPreferences`. The Manifest fragment registers the
plugin; the source files alone do not activate it.

## Configure and export

Install the matching official `version.txt` and `android_release.apk` companion
files under the editor's `export_templates/4.7.2.stable/` directory. The patched
source template has already been extracted into the stage.

Configure the editor's `export/android/android_sdk_path` and
`export/android/java_sdk_path` to your final-export SDK and Java installation.
Use SDK 35 / Build Tools 35.0.1, NDK 28.1.13356709 and Java 17 or later. The
Gradle wrapper downloads its declared dependencies when first used; no private
offline Gradle cache is required by the public source.

In the staged `export_presets.cfg`, retain:

- `gradle_build/use_gradle_build=true`.
- `gradle_build/compress_native_libraries=true`.
- `gradle_build/min_sdk="30"` / `gradle_build/target_sdk="35"`.
- ARM64 enabled and the other ABIs disabled.
- Package ID `org.easyrpg.rpggodo2003` when continuing the existing app identity.

Set the intended `version/code` and `version/name` in that staged preset.
The latest local candidate used 26 / `0.0.2d-rc1-surfacefix`; the source preset's
development defaults remain unchanged. Set `keystore/release`,
`keystore/release_user` and `keystore/release_password` only in the private
staged preset, or through the editor's export configuration. Never put private
signing inputs into the published source tree. Updating an existing installation
requires its compatible signing identity.

Create the output directory and run the official 4.7.2 editor:

```text
godot --headless --path <staged-project> --editor --import
godot --headless --path <staged-project> --export-release "Android P3" <output-directory>/RPG-Godo-2003.apk
```

Native-library compression is intentional: Android extracts the libraries at
installation. The patched AAR, native bridge, input-plugin classes and Manifest
registration all need to be present in the final APK. Complete package and
device acceptance is a release step after source preparation; this directory
contains no prebuilt APK and no generated attestation.
