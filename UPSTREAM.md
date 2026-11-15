# Upstream pins

Snapshot of the private Vivecraft port at commit `7c4407952bb31ae4b8bb67c7b51a96742ce69df7` (branch `vivecraft`). The earlier plan pin `273eed9f` is behind this commit. The Minecraft 26.3 port (branch `mc-26.3`, merged for release 1.0.3) was done in this tree, on top of that snapshot. This file records the pins. It does not vendor the JDKs, the Minecraft client, or the mod jars.

## ANGLE

- Source: https://chromium.googlesource.com/angle/angle.git at `25e721127e1c6c4c6fa0182b5c234b2c88971175`
- depot_tools: `6afa997717b2c0e1382e1465bedbe1a6855b9388`
- Patch: `angle-patches/klepton.patch`
- Committed frameworks (BSD-3-Clause notice in `vendor/out/LICENSE`):

The committed copies below had their compile-path prefix rewritten in place (`visionos/scrub_paths.py`) and were re-signed ad-hoc. The hashes are of those files. A raw ANGLE build on another machine will not match them byte for byte.

| File | sha256 |
| --- | --- |
| `vendor/out/xros/libEGL.framework/libEGL` | `2c0b97395e75c38a4e0c491f45fb61d265fcdbe7241e8655f835a18e41fb6bd1` |
| `vendor/out/xros/libGLESv2.framework/libGLESv2` | `4dad972e8ec6e034b2af8b9446abc0c73a3e1f6392faf3be77989439a1c6d483` |
| `vendor/out/xrsim/libEGL.framework/libEGL` | `4f0d9a68d33b0d93007db145821e91a5fe0beefbcb5d57f1929155b5da09fdb0` |
| `vendor/out/xrsim/libGLESv2.framework/libGLESv2` | `ca755f46b36d226325d0c9f602335dc3bab9aaadfbd35ec42287044638f5748f` |

## Vivecraft

Minecraft 26.3 (release 1.0.3 onward):

- Base: https://github.com/Vivecraft/VivecraftMod branch `Multiloader-26.3` at `15a9011fd5eb7816d44e168256814fc4b5c24c04` ("bump to 1.3.18", mod 1.3.18).
- Patch 0000 (`work/vivecraft-openxr-26.3/patches/0000-openxr-on-26.3.patch`): upstream's `openxr` branch at `13eafae17a987521cc270e81cd774a4746ad9299` merged onto `15a9011f` (merge base `dee18e33`), conflicts resolved and the openxr-only code adapted to 26.3 (`com.mojang.blaze3d.*` → `com.mojang.renderpearl.*`, SDL3 instead of GLFW, LWJGL OpenXR 3.4.3), squashed to one commit. It is upstream LGPLv3 code by the Vivecraft authors, not ours. Upstream has not moved `openxr` past 26.2. Resolutions are listed in `work/vivecraft-openxr-26.3/REPORT.md`.
- Patches 0001–0006 (same subjects and authors as the 26.2 set, rebased): 0001–0005 are the port. 0006 (from [zschwendi/avp-craft](https://github.com/zschwendi/avp-craft)) lowers the head-locked in-world HUD (new-profile default −8°).
- Patch 0007 (this fork, 2026-11-15): no "Seated" play mode on the mobile path. Seated play reads keyboard and mouse and skips the VR controllers; on a headset without either it locked the player out. 26.3 only; the 26.2 set is unchanged.
- Git trees: after 0000 `3c35acf95a067826a2c0fb2a2193ee06920cd0ee`; after 0000–0005 `3699b3f2a362c30c9050a9780a7bde264a883104`; after 0000–0006 `b0488a1e424191a8d9b95afde53d46b54d294282`; after 0000–0007 `9f23d5f57f45c63278987abaef03a921d5f21b65`.
- Jar (0000–0007, canonicalized with `work/vivecraft-openxr-26.2/canonicalize-vivecraft-jar.py`): `vivecraft-26.3-1.3.18-fabric.jar`, 19,770,429 bytes, sha256 `5c2df5a85e9d76e768203dd4d38e247fd0c052330ad62e7985ef8bcdd197f913`. Built 2026-11-15, same tools as below; this is the jar `mods-26.3.json` and `tools/avpplay/build_parts.sh` pin.
- Jar (0000–0006, release 1.0.3): 19,769,483 bytes, sha256 `5092c004f1ab35185dd0e428ad8ff5c4d6c887f72c861649dabb00544f147d87`. Built 2026-11-07 (0006 at −8°) with GraalVM 25.0.4+7.1, Gradle 9.3.0, Loom 1.15.5, fabric-loader 0.19.5, Fabric API 0.165.2+26.3 (upstream's `gradle.properties` says 0.160.4+26.3). Two builds gave the same canonical hash; their raw Loom jars differed.
- Nested LWJGL OpenXR: 3.4.3 (patch 0000 bumps `lwjgl_openxr_version` from 3.4.1).
- License: LGPLv3 (`LICENSES/LGPL-3.0.txt`)

**The 1.0.3 image has patch 0006** and not 0007. It is the first shipped image that has 0006. ni id: `3e783e38b00b` (`out/t8-26.3`, built as `out/t8-26.3c`, `klmc t8a 2026-11-07T23:08Z`).

Minecraft 26.2 (releases 1.0.1 and 1.0.2, tag `1.0.2`):

- Upstream `openxr` at `13eafae1` plus `work/vivecraft-openxr-26.2/patches/` 0001–0006. Tree after 0001–0006 `bc542a09e32f6f9b74f54ddb4a37373d2b32c902`; after 0001–0005 `68f88122e716fdbb7f6613490503739c9baf07c2` (`8297f0ecc84bb25aecf714c23dae661cf6cdf626` is the private commit id of patch 0005, not a tree).
- Canonical jar (0001–0006): `vivecraft-26.2-1.3.15-fabric.jar`, 19,032,717 bytes, sha256 `f317964c49f8e1dace17dcc4ea4a8d4f9d29c7e5a2888c61b73259f4355deac4` (Fabric API 0.161.0+26.2).
- The 1.0.1 and 1.0.2 image was baked from 0001–0005 (raw Loom jar sha256 `e241a4c2888bd7158e5177916b6f524b862801c192a08f7d967fc3f21ee5be7d`, canonical `5324e012fe0072cb7471e36349d40395d2ab63a7e8f9609f0b35a67a53a0d62b`), so it does not have the lower HUD.

## LTW

- https://github.com/PojavLauncherTeam/ltw at `7703f1c29a1fd7f151484c38fb7563bb79ca8ccb`
- Darwin port in `work/natives/ltw/`. License: LGPL-3.0.
- Minecraft 26.3 additions to the Darwin port: `darwin/ltw_darwin_shader.c` (a failed conversion yields an ESSL `#error` stub instead of NULL; non-constant fragment-output array indexing rewritten), `darwin/ltw_darwin_glslconv_limits.h` (uniform-block limit 4 → 12, force-included into `GlslConvert.cpp`), and section 7c of `darwin/ltw_darwin_gl33.c` (indexed blend / color-mask state through `EXT`/`OES_draw_buffers_indexed`). The upstream checkout is still compiled unmodified.

## GraalVM

- Oracle GraalVM JDK 25.0.4+7.1
- URL: https://download.oracle.com/graalvm/25/latest/graalvm-jdk-25_macos-aarch64_bin.tar.gz
- Tarball: 353,673,229 bytes, sha256 `0b79e23c133facbad2f7aa55a3b76d17bd59d2fa15e2735bb63391ace223fd13` (recorded when it was fetched; the tarball was not on disk for this snapshot, so this hash was not recomputed)
- Installed `Contents/Home/release`: `JAVA_VERSION=25.0.4`, `JAVA_RUNTIME_VERSION=25.0.4+7-LTS-jvmci-b01`, `GRAALVM_VERSION=25.0.4`
- Terms: https://www.oracle.com/downloads/licenses/graal-free-license.html
- JDK 21.0.12 (sha256 `a98948c3a1ad037fe2dde5c80b06b214a5f80c120d8fc2453d155508cf677beb`) is only for a `MCV=1.*` bake. This image uses JDK 25.

## Natives

Minecraft 26.3. `work/natives/scripts/lwjgl-ver.sh` holds the LWJGL / FreeType / libffi pin table (MCV 26.2 → 3.4.1, 26.3 → 3.4.3; `LWJGL_VER` overrides). Download rows: `work/natives/PROVENANCE.md`.

| What | Pin |
| --- | --- |
| LWJGL 3.4.3 | tag `3.4.3`, commit `30fac9b95f99cda97312232be25ba55297bf9951`. Maven Central jars, incl. `lwjgl-sdl`, `lwjgl-shaderc`, `lwjgl-spvc`: `work/natives/downloads/lwjgl-3.4.3-maven/SHA256SUMS` |
| FreeType 2.14.3 | tag `VER-2-14-3`, commit `0a0221a1347e2f1e07c395263540026e9a0aa7c7`, tag archive sha256 `dc49de6b01a266eef4876a4dd34d9842c475d3e28ff2eff63bd2fb760ab56261` |
| libffi 3.8.0 | https://github.com/libffi/libffi/releases/download/v3.8.0/libffi-3.8.0.tar.gz, sha256 `7da3e2d9a171eb0a038f592ecad3ff2bb2550f3496d87b3b29ad0cf4430c0db4` |
| shaderc | google/shaderc `2c8cae778eec0283b44acbe7ed1a386865d78799` ("Finalize Shaderc v2026.3"; the commit `lwjgl-shaderc-3.4.3-natives-macos-arm64.jar` names) |
| glslang | KhronosGroup/glslang `168d452a4f460d24b588fed08477a81c44ee27a1` (shaderc DEPS) |
| SPIRV-Tools | KhronosGroup/SPIRV-Tools `b707790a898e44038547df54580022fc1cf89c3d` (shaderc DEPS) |
| SPIRV-Headers | KhronosGroup/SPIRV-Headers `29981f65241605e08b0ede4cfeb999fe3b723c6a` (shaderc DEPS) |
| SPIRV-Cross | KhronosGroup/SPIRV-Cross `6c09849fe88c48eaed08413aa022aaa136a3a057` (the commit `lwjgl-spvc-3.4.3-natives-macos-arm64.jar` names) |
| OpenXR-SDK 1.1.49 | sha256 `74e9260a1876b0540171571a09bad853302ec68a911200321be8b0591ca94111` |
| Phonon SOFA (`runtime/data/phonon_hrtf_cipic_124.sofa`) | sha256 `c28ff4a874ac889ec0c5885ca524762a70d56984232ff7aadcd9c15d32e1cfb6` (Apache-2.0, Valve steam-audio) |

shaderc, glslang, SPIRV-Tools, SPIRV-Headers and SPIRV-Cross are git checkouts at those commits (`work/natives/scripts/build-shaderc-spvc.sh` checks HEAD, and checks that the stock 3.4.3 natives jars name the same shaderc and SPIRV-Cross commits). The rest of shaderc's DEPS (googletest, effcee, re2, abseil-cpp) is tests only and is not fetched.

SVC codec pins are in `work/natives/svc/PROVENANCE.md`.

Minecraft 26.2 (tag `1.0.2`): LWJGL 3.4.1 commit `b800ccffab14396fc529ddb6c931b7c5c5226763`; FreeType 2.14.1 commit `526ec5c47b9ebccc4754c85ac0c0cdf7c85a5e9b`, tag archive sha256 `44bd69d1f0750603410cfd4f26f1c5523c5a3a087a2dfa8639b757dc7c6677be`; libffi 3.5.2 sha256 `f3a3082a23b37c293a4fcd1053147b371f2ff91fa7ea1b2a52e335676bac82dc`. No shaderc or SPIRV-Cross natives.

## SDL3

The app ships no SDL3. Minecraft 26.3 replaced GLFW with SDL3 (`lwjgl-sdl` 3.4.3, whose stock natives name `libSDL3.dylib.git` = `147a8ee32dbf9ac02f3794964490687b6bbda1bc`). `work/native-image/scripts/t2/build-klsdl.sh` builds `lwjgl-sdl-klsdl-3.4.3.jar`: the stock jar's `SDL_*` struct and callback classes (LWJGL, BSD-3-Clause, used as they are) plus our function classes (`work/native-image/scripts/t4-src/java-sdl/org/lwjgl/sdl/`), and `libklsdl.dylib` (`scripts/t4-src/native/klsdl.c`, which includes `klglfw.c`). A coverage gate fails the build unless every `org/lwjgl/sdl` member the 26.3 classpath references resolves (150/150 at the time of the port). The stock `libSDL3.dylib` is used only by the host JVM for the Knot bake.

## Native image

Release 1.0.3 (Minecraft 26.3, Vivecraft 0000–0006). These dylibs are build outputs, not in git.

| File | sha256 |
| --- | --- |
| `out/t8-26.3/xros/libminecraft.dylib` | `b97d9970da59b945ffddf691e1416b19cecd30086bc0859275ea8f18c8fec587` |
| `out/t8-26.3/xrsimulator/libminecraft.dylib` | `b07e998d61cf81ed4e2b31d9c4a4d41c88d9f139d51d7cea0b06485ec508e199` |

Image id string on the xros dylib: `klmc t8a 2026-11-07T23:08Z xros ni=3e783e38b00b`. These hashes are of the image the OTA 1.0.2.x builds carried (HUD default −15°); the 1.0.3 image with the −8° default replaces them.

Releases 1.0.1 and 1.0.2 (Minecraft 26.2, Vivecraft 0001–0005), built in the private tree:

| File | sha256 |
| --- | --- |
| `libminecraft.dylib` (xros) | `9473c5f6db18ee14115bf43fe31a68cd8590034ded76eb5795e34978c30664c9` |
| `libminecraft.dylib` (xrsimulator) | `19f17ce381c0b5770f26238a9f824f2738811da0b1f8504cc1bedbcca340e2f2` |

Image id string on the xros dylib: `klmc t8a 2026-10-14T16:51Z xros ni=3e91b06a7df9`.

## AVP Play parts build

`tools/avpplay/build_parts.sh` (BUILDING.md, "Unattended parts build") fetches three archives into its work folder and checks each by sha256. The table is repeated at the top of the script.

| What | URL | Bytes | sha256 |
| --- | --- | --- | --- |
| CMake 4.3.3 | https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-macos-universal.tar.gz | 87,452,640 | `5221a13450c7a0219a2a0d1b6c9085eb06489721fafd8488ccebc1584175d2fb` |
| Ninja 1.13.2 | https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-mac.zip | 314,051 | `c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b` |
| Oracle GraalVM JDK 25.0.4+7.1 | https://download.oracle.com/graalvm/25/archive/graalvm-jdk-25.0.4_macos-aarch64_bin.tar.gz | 353,673,229 | `0b79e23c133facbad2f7aa55a3b76d17bd59d2fa15e2735bb63391ace223fd13` |

CMake's hash is the one in Kitware's `cmake-4.3.3-SHA-256.txt`, Ninja's the digest GitHub lists for the release asset, GraalVM's the `.sha256` Oracle serves beside the archive; all three were read on 2026-11-15. The GraalVM archive is the tarball of the GraalVM section above under its versioned address. CMake 4.3.3 and Ninja 1.13.2 are the versions the 2026-11-14 build of this tree ran with.

Committed inputs of that script:

- `tools/avpplay/pins/lwjgl-3.4.3-maven.sha256`: the 26 LWJGL 3.4.3 jars `fetch-lwjgl341.sh` downloads (`downloads/lwjgl-3.4.3-maven/SHA256SUMS` of the Natives section). The sha1 of each file equals the `.sha1` Maven Central serves for it (checked 2026-11-15).
- `tools/avpplay/pins/baked-26.3.cp`: `klepton-payload/baked.cp` of release 1.0.3 (the IPA named below), 138 classpath entries relative to `work/native-image`. The build's own classpath must equal it line for line before the image is built.
- `tools/avpplay/bake-failures-26.3.txt`: the 46 class names of BUILDING.md section 6, sorted, from a bake of this tree on 2026-11-14 (sha256 of the file `b90f63fa6da2793fd84ffee48e6489dc91b37a031fe66744f7da9cd59781a675`).
- `tools/avpplay/defaults/fgamedir/`: `options.txt` and `config/` of release 1.0.3's payload (`klepton-payload/root/inst-26.3/fgamedir` in `vivecraft-visionos-1.0.3.ipa`, sha256 `ece6db2e0e3cf0c04e542730a3af2279e2ad4bae463967c06c9f081cf40c5f9b`), byte for byte, without `config/sodium-fingerprint.json`. That file holds salted hashes of the builder's account id and game path; Sodium writes a new one whenever the stored one does not match, which is the case on every other device. `modernfix-mixins.properties` and `smoothboot.json` belong to mods this build does not carry and are kept because the release has them. `tools/avpplay/defaults/options-overrides.txt` holds AVP Play's own rows (render distance 5, simulation distance 8).
- `tools/avpplay/mkworld/MkWorldAgent.java`: our code, under this repository's `LICENSE`. It calls Minecraft by reflection and contains none of it.
- `tools/avpplay/quietwindow/quiet_window.m`: our code, under this repository's `LICENSE`. It uses AppKit and the Objective-C runtime only; the hint names it relies on beside it (`SDL_MAC_BACKGROUND_APP`, `SDL_WINDOW_ACTIVATE_WHEN_SHOWN`, `SDL_WINDOW_ACTIVATE_WHEN_RAISED`) are strings in LWJGL 3.4.3's `libSDL3.dylib` and were read in SDL 3.4.14's sources (the library reports `SDL-3.4.14-62f10da`, the note beside it in the natives jar names `147a8ee32dbf9ac02f3794964490687b6bbda1bc`; `SDL_cocoaevents.m`, `SDL_cocoawindow.m`, `SDL_cocoamouse.m` and `SDL_mouse.c` are the same at both).

`work/native-image/inst-26.3/config/t23-trim/reachability-metadata.json` on this branch registers one more field, `TransitionConfig.disableRecipeBookCodes` (`SOURCE.txt` beside it). An image built from this branch is therefore not the 1.0.3 image of the Native image section, and its payload is not the 1.0.3 payload: image and payload of one build belong together.
