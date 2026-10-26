# OpenImmersiveLib

_A free and open source spatial & immersive video player Swift Package for visionOS._

Maintained by [Anthony Maës](https://www.linkedin.com/in/portemantho/) & [Acute Immersive](https://acuteimmersive.com/), derived from [Spatial Player](https://github.com/mikeswanson/SpatialPlayer/) by [Mike Swanson](https://blog.mikeswanson.com/).

Built for Swift 6.2 & visionOS 26.

Refer to the main [OpenImmersive repo](https://github.com/acuteimmersive/openimmersive) for more details.

## MVC MKV playback

MVC support is built into the existing `OpenImmersiveLib` product. Blu-ray MVC
`.mkv` and `.mk3d` URLs automatically use the native decoder. Other formats retain
AVFoundation playback, including HLS, MV-HEVC, frame-packed SBS/over-under and AIV.

```swift
import OpenImmersive

let item = VideoItem(metadata: [.commonIdentifierTitle: "Movie"], url: fileURL)
// Or an extensionless original HTTP resource:
let stream = VideoItem(metadata: [:], url: mediaURL, playbackEngine: .mvc)
ImmersivePlayer(selectedItem: item)
```

MVC defaults to rectangular stereo projection and rejects spherical/AIV projection
or SBS/over-under packing. The existing control panel supports play/pause, ±15 s,
scrubbing, volume, embedded audio-track selection and eye swapping. `VideoPlayer`
exposes `embeddedAudioTracks`, `selectedEmbeddedAudioTrackID`,
`selectEmbeddedAudioTrack(id:)`, `eyesSwapped`, `swapEyes()`, `mvcDiagnostics`, and
`mvcDiagnosticReport()`. Embedded track IDs are demux stream IDs, not array indices.
The HLS `AudioOption` API is unchanged. `VideoPlayer.player` remains available for
AVFoundation consumers; MVC commands/time must use the controller. Opening prepares
MVC playback without autoplay; `play()`/`pause()` work during asynchronous opening.

The library's **Open from Files** picker accepts MKV/MK3D. **Enter Stream URL**
accepts direct HTTP(S) MKV resources; enable MVC explicitly for extensionless URLs.
Servers must return validated partial byte responses. Compressed HTTP caching is
bounded to 32 MiB; ignored, incorrect and truncated ranges fail rather than causing
a full-file download. No SMB or UPnP discovery dependencies are included.

Host applications accessing local servers need `NSLocalNetworkUsageDescription`
and appropriate ATS settings. The companion app uses `NSAllowsLocalNetworking`
for unencrypted local HTTP; remote URLs should use HTTPS. The host owns network
policy. File access is security-scoped for the playback lifetime, including stop,
replacement and controller destruction.

Supported MVC input is progressive 8-bit 4:2:0 Blu-ray MVC, at most 1920×1088 per
eye. Embedded audio is decoded into labeled PCM, preserving channel-based 5.1/7.1
mixes and a rational sample clock. There is no silent 2D fallback for ordinary or
unsupported MKVs. Subtitles, ISO/BDMV, HDR, interlaced MVC, general MKV playback,
Atmos/DTS:X objects and bitstream passthrough are outside this implementation.
The default is four decoder workers. Hardware acceptance initially targets M5;
other devices retain their existing format support but MVC throughput is unverified.

## Native builds and tests

The shipped package downloads a checksum-pinned XCFramework (Apple Silicon macOS,
visionOS device and arm64 simulator). A source checkout needs Xcode 26+ with
visionOS SDKs, Swift 6.2, Python 3.12+ and Git to rebuild it:

```sh
python3 Scripts/build_native.py
python3 Scripts/test_core.py
xcodebuild -scheme OpenImmersive -destination 'platform=visionOS Simulator,name=Apple Vision Pro' test
```

`test_core.py` stages the production core into a macOS validation package without
adding macOS to the public visionOS UI product. Tests generate deterministic MVC
fixtures from pinned conformance material, compare both eyes and reordered PTS,
and verify channel layouts, DTS timing, seeks, HTTP handling and cancellation.
Simulator tests cover the public controller and real decoder/sample path. Paced
playback with a compositor surface, listening tests and external A/V measurements
require the full app. See [validation results](Validation/RESULTS.md) and the
[M5 acceptance procedure](Validation/HARDWARE_VALIDATION.md).

The small committed MKV test fixtures can be regenerated with
`Scripts/make_test_fixture.py`. No user movies or network credentials are committed.

`Scripts/package_native.py` packages the XCFramework plus matching source and
relinking materials. See [dependency notices](THIRD_PARTY_NOTICES.md) before
redistributing an application. The native asset is currently hosted on the
contributor fork. Before upstream release, mirror the immutable assets under
maintainer control and update the URL in `Package.swift` while retaining the
verified checksum (or rebuild and publish a new version/checksum).
