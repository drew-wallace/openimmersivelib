#ifndef MVC_AUDIO_CLOCK_H
#define MVC_AUDIO_CLOCK_H
#include <stdint.h>
#include <stdlib.h>
#include <libavutil/mathematics.h>
#include <libavutil/avutil.h>

// Container timestamps can be quantized more coarsely than one PCM sample.
// Keep a rational sample counter between real discontinuities; don't move the
// audio renderer's start time backward/forward for every rounded MKV packet.
typedef struct {
    int64_t anchor_us, samples;
    int rate;
    int initialized;
} MVCAudioClock;

static inline int64_t mvc_audio_clock_push(MVCAudioClock *clock, int64_t source_us,
    int samples, int rate, int64_t tolerance_us) {
    if (rate <= 0 || samples < 0) return AV_NOPTS_VALUE;
    if (!clock->initialized || clock->rate != rate) {
        if (source_us == AV_NOPTS_VALUE) return AV_NOPTS_VALUE;
        clock->anchor_us = source_us; clock->samples = 0; clock->rate = rate; clock->initialized = 1;
    }
    int64_t predicted = clock->anchor_us + av_rescale(clock->samples, 1000000, rate);
    if (source_us != AV_NOPTS_VALUE && llabs(source_us - predicted) > tolerance_us) {
        clock->anchor_us = source_us; clock->samples = 0; predicted = source_us;
    }
    clock->samples += samples;
    return predicted;
}
#endif
