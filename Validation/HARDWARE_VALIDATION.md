# M5 acceptance procedure

Use a Release build on physical M5 hardware. Keep JSON reports separate for each source, route, and worker count. Simulator and Mac results are development checks only.

1. Run the L/R pattern. Confirm L appears only in the left eye and R only in the right, including after eye swap. Check 1080p sharpness, aspect ratio, black levels, and cropping on a known reference.
2. Run 5.1 and 7.1 channel signals on your chosen audio route. Confirm the displayed channel matches the perceived direction and LFE is present. Record route/spatial-audio settings. Validate real DTS-HD and TrueHD mixes separately; no Atmos/DTS:X object preservation is claimed.
3. Use the source-level validation harness to benchmark a representative MVC movie with 2/4/6/8 workers for ten minutes each (the shipping control panel uses four workers). Require at least 1.3× source fps, no concealed pairs or decoder errors, and acceptable thermal state. Choose the lowest passing count.
4. Play at least sixty minutes, including high-bitrate scenes, locally and through HTTP. Confirm bounded memory and no sustained thermal/network buffering. The app reports late-pair drops and submissions; use Instruments and visual checks to detect renderer/compositor drops. Require total observed post-startup pair loss below 0.1%.
5. Measure audio/video alignment using an appropriate flash/click clip and an external timing setup. Require steady-state error within ±40 ms. Queue timestamps alone are not an acoustic measurement.
6. Repeat forward/backward seeks, seek while paused, rapid successive seeks, eye swap, audio-track changes, EOF/replay, route changes, and interruptions. Confirm no stale-eye pairs or old audio appear after a transition.
7. Interrupt HTTP connectivity during an active read. Verify a clear error or coordinated buffering, a responsive UI, and stop/open recovery. Validate local-network permissions with your actual server. Automatic reconnect after a permanent read failure is not implemented.

Record failures with source format, playback timestamp, selected audio index, route, OS version, worker count, thermal state, and the exported report. Keep source URLs/credentials out of reports you share publicly.
