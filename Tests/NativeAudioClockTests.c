#include <assert.h>
#include <math.h>
#include "audio_clock.h"

int main(void) {
    MVCAudioClock clock = {0};
    // Ten minutes of 48 kHz DTS blocks in a millisecond-timebase container.
    // The first packet is the anchor; subsequent rounding must never create
    // an audio gap/overlap, and accumulating rounded durations must not drift.
    for (int64_t frame = 0; frame < 56250; ++frame) {
        int64_t exact = av_rescale(frame * 512, 1000000, 48000);
        int64_t rounded = (exact / 1000) * 1000;
        assert(mvc_audio_clock_push(&clock, rounded, 512, 48000, 2000) == exact);
    }
    int64_t discontinuity = 700000000;
    assert(mvc_audio_clock_push(&clock, discontinuity, 512, 48000, 2000) == discontinuity);
    assert(mvc_audio_clock_push(&clock, AV_NOPTS_VALUE, 512, 48000, 2000) == discontinuity + av_rescale(512, 1000000, 48000));
    clock = (MVCAudioClock){0};
    assert(mvc_audio_clock_push(&clock, AV_NOPTS_VALUE, 512, 48000, 2000) == AV_NOPTS_VALUE);
    assert(mvc_audio_clock_push(&clock, 123456, 1024, 44100, 2000) == 123456);
    assert(mvc_audio_clock_push(&clock, 200000, 512, 48000, 2000) == 200000);
    return 0;
}
