# Native dependency notices and redistribution materials

OpenImmersive remains MIT licensed. The MVC core was adapted from MVCVision
(MIT, copyright 2026 MVC Vision contributors); its license is retained in
`Sources/Notices/MVCVision-MIT.txt`.

| Component | Configuration/license | Pinned source |
|---|---|---|
| edge264-mvc | BSD-3-Clause | `dependencies.json`, `Vendor/edge264-mvc/LICENSE_BSD.txt` |
| FFmpeg 8.0.1 | LGPL-2.1-or-later; GPL/nonfree disabled | `dependencies.json`, `Vendor/ffmpeg/COPYING.LGPLv2.1` and `LICENSE.md` |

`Sources/Notices` is copied into the Swift package resource bundle, so license
texts travel with the library. SMB/libsmb2 are not dependencies of this product.

The native release contains:

- `CMVC.xcframework.zip`: the macOS arm64, visionOS arm64, and simulator arm64
  static library slices, public C header, and module map.
- `CMVC-source-and-relink.tar.gz`: the exact third-party source trees, bridge
  source, pinned dependency manifest, build and packaging scripts, license texts,
  and per-platform native object/static-library files.
- `native-artifact.json`: SHA-256 hashes and dependency revisions.

`Scripts/build_native.py` verifies downloaded source checksums and builds without
GPL, nonfree, autodetected codecs, or FFmpeg networking. Only Matroska demuxing
and the listed audio decoders are enabled. Byte transport belongs to Swift.
`Scripts/package_native.py` produces the release archives. The XCFramework URL and
checksum are pinned in `Package.swift`.

When distributing an application containing these statically linked LGPL
components, retain and provide the corresponding source, build instructions,
modifications, and the application object files/materials needed to relink with a
modified LGPL library, under the applicable license terms. The native release
provides the library-side materials; an app distributor must supply its own
application/Swift objects and link instructions from its matching build. The
library repository and license bundle alone are not a complete application
redistribution package. See the included full LGPL text.

The short test MKVs are generated from official JVT MVC conformance material and
synthetic PCM, not user media. Upstream fixture provenance is retained in the
native source archive and described in `Tests/OpenImmersiveTests/Fixtures`.
