# MVC integration validation

Initial target: M5 Vision Pro, visionOS 26+. Development host: Xcode 27.0,
Apple Silicon Mac, visionOS 27 simulator. Run dates: October 26, 2026.

- Host core suite: 16 tests pass, covering both-eye reference hashes at
  1/2/4/6/8 workers, B-frame timestamps, seeks/audio trimming, stereo rejection,
  channel layouts, sample-clock timing, bounded HTTP reads and cancellation.
- Simulator suite: 13 controller/integration tests pass. Includes legacy Codable
  values with metadata, engine routing, early play/pause, scrub/skip/volume,
  embedded track IDs, swap, EOF callback routing, stale callbacks, real paired
  MVC output and six-channel PCM, rapid seeks, explicit pause during interruptions,
  SBS/over-under/AIV routing, and ordinary MKV rejection.
- Full app Release simulator and device builds succeed using the local library integration.
- Upstream edge264-mvc `make check` passes: 151/151 conformance fixtures in
  the tested threaded/paced variants, plus API, liveness, stress and robustness.

- Clean remote checkout: SwiftPM downloads the immutable, checksum-pinned native
  asset and both device/simulator builds pass without local Artifacts or Vendor.
- Full app in simulator with an attached RealityView: both local and extensionless
  HTTP fixture playback reach EOF and replay. Each pass submits all nine stereo
  pairs with six-channel PCM, zero late drops/rebuffers and no renderer errors.
  HTTP reports are in Reports/simulator-http-run-{1,2}.json (counters are cumulative
  after replay). A temporary app copy supplied the test URL/fixture and collected
  diagnostics; those test hooks are not part of the app PR.
- Physical M5 smoke test passes on `RealityDevice17,1`, visionOS 27.2 (24N120),
  using the Release app built from library revision
  `339fa3eda223360b6b979a5be4a09758f989e4a5`. Both bundled local and extensionless
  HTTP playback reach EOF and replay through the app's RealityView. Each pass
  submits all nine stereo pairs and six-channel PCM; both transports report zero
  renderer errors, late drops, concealed pairs, rebuffer events and audio timing
  gaps, with nominal thermal state. Raw reports are in
  `Reports/m5-{local,http}-run-{1,2}.json`; counters are cumulative after replay.
  The initial HTTP attempt returned the OS's offline error; reopening the app
  succeeded. Automatic retry after network-permission/connectivity errors is not
  implemented.

The physical smoke fixture is only 0.375 seconds at 640×480 per eye and contains
six-channel PCM silence. It verifies native integration, renderer submission and
EOF/replay, not sustained 1080p movie throughput, audible channel routing or
physical eye orientation. Test hooks remain in the temporary app copy only.

The simulator's test runner has no compositor surface; the real-decoder test checks
sample production rather than claiming paced EOF or physical presentation.

Remaining hardware acceptance: ten-minute M5 thread sweeps, sixty-minute sustained
playback/thermal/memory checks, physical L/R and 5.1/7.1 listening tests, route and
interruption behavior, and external ±40 ms acoustic A/V alignment. MVCVision's
previous short M5 results are reference evidence, not acceptance of this integrated
player. Do not call the integrated player hardware-validated until those checks
are recorded. See HARDWARE_VALIDATION.md.
