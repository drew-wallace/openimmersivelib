# Native dependency notices

OpenImmersive is MIT licensed. Full license texts ship in the package resource bundle.

| Dependency | License | Source |
|---|---|---|
| edge264-mvc | BSD-3-Clause | Pinned in dependencies.json |
| FFmpeg 8.0.1 | LGPL-2.1-or-later, GPL/nonfree disabled | Pinned in dependencies.json |

Scripts/build_native.py verifies pinned source archives and builds arm64 macOS,
visionOS device and simulator slices. FFmpeg networking, GPL/nonfree and autodetected
components are disabled. Swift supplies byte transport; FFmpeg demuxes Matroska
and decodes the configured audio formats.

The native release includes CMVC.xcframework.zip, matching source and relinking
objects in CMVC-source-and-relink.tar.gz, and SHA-256 hashes in native-artifact.json.
Scripts/package_native.py creates these materials. Package.swift pins the binary
URL and checksum. Before an upstream release, mirror the assets under maintainer
control and update the URL while retaining the verified checksum, or publish a new
artifact version/checksum.

Application distributors must also provide their matching application/Swift objects
and link instructions needed to relink the statically included LGPL components,
under the included license terms. The native source/relinking archive supplies the
library-side materials. See Sources/Notices for the full licenses.
