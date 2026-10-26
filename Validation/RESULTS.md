# MVC integration validation

Initial target: M5 Vision Pro, visionOS 26+. Development host: Xcode 27.0,
Apple Silicon Mac, visionOS 27 simulator. Run dates: October 26, 2026.

- Host core suite: 16 tests pass, covering both-eye reference hashes at
  1/2/4/6/8 workers, B-frame timestamps, seeks/audio trimming, stereo rejection,
  channel layouts, sample-clock timing, bounded HTTP reads and cancellation.
- Simulator suite: 11 controller/integration tests pass. Includes legacy Codable
  values with metadata, engine routing, early play/pause, scrub/skip/volume,
  embedded track IDs, swap, EOF callback routing, stale callbacks, real paired
  MVC output and six-channel PCM, and ordinary MKV rejection.
- Full app Release simulator and device builds succeed using the local library integration.
- Upstream edge264-mvc `make check` passes: 151/151 conformance fixtures in
  the tested threaded/paced variants, plus API, liveness, stress and robustness.

The simulator's test runner has no compositor surface; the real-decoder test checks
sample production rather than claiming paced EOF or physical presentation.

Remaining hardware acceptance: ten-minute M5 thread sweeps, sixty-minute sustained
playback/thermal/memory checks, physical L/R and 5.1/7.1 listening tests, route and
interruption behavior, and external ±40 ms acoustic A/V alignment. MVCVision's
previous short M5 results are reference evidence, not acceptance of this integrated
player. Do not call the integrated player hardware-validated until those checks
are recorded. See HARDWARE_VALIDATION.md.
