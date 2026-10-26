#ifndef CMVC_H
#define CMVC_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct MVCDecoder MVCDecoder;
// read_at: positive byte count, zero at EOF, negative on failure/cancellation.
// All callbacks run on the decoder worker, never on the main thread.
typedef int (*MVCReadAt)(void *, int64_t, uint8_t *, int);
typedef struct { void *context; MVCReadAt read_at; int64_t size; } MVCIO;
typedef struct {
    int index, channels, sample_rate;
    char codec[32], language[32], title[128];
} MVCAudioTrack;
typedef struct {
    int width, height, full_range, color_primaries, color_transfer, color_matrix;
    int sar_num, sar_den, base_is_right, audio_count;
    double fps, duration;
    MVCAudioTrack audio[32];
} MVCMediaInfo;
typedef struct {
    const uint8_t *base_y, *base_u, *base_v, *dependent_y, *dependent_u, *dependent_v;
    int width, height, chroma_width, chroma_height, stride_y, stride_c;
    int64_t pts_us, duration_us, display_order;
    uint32_t flags;
} MVCVideoFrame;
// Channel IDs use MVCChannel, in the exact order of the interleaved PCM samples.
typedef enum {
    MVC_CH_UNKNOWN = 0, MVC_CH_LEFT, MVC_CH_RIGHT, MVC_CH_CENTER, MVC_CH_LFE,
    MVC_CH_BACK_LEFT, MVC_CH_BACK_RIGHT, MVC_CH_SIDE_LEFT, MVC_CH_SIDE_RIGHT,
    MVC_CH_BACK_CENTER
} MVCChannel;
typedef struct {
    const float *samples;
    int sample_count, sample_rate, channels;
    MVCChannel channel_ids[8];
    int64_t pts_us;
} MVCAudioFrame;
typedef int (*MVCVideoCallback)(void *, const MVCVideoFrame *);
typedef int (*MVCAudioCallback)(void *, const MVCAudioFrame *);
typedef struct { void *context; MVCVideoCallback video; MVCAudioCallback audio; } MVCCallbacks;

MVCDecoder *mvc_create(MVCIO io, MVCCallbacks callbacks, int threads);
int mvc_open(MVCDecoder *decoder);
const MVCMediaInfo *mvc_info(MVCDecoder *decoder);
// 1: progress, 0: fully drained EOF, -1: error, -2: cancelled.
int mvc_step(MVCDecoder *decoder);
// Call only after the previous step has returned. Seeks backward and discards preroll.
int mvc_seek(MVCDecoder *decoder, int64_t target_us, int audio_stream_index);
// The only function safe to call concurrently with open/step/seek.
void mvc_cancel(MVCDecoder *decoder);
void mvc_reset_cancel(MVCDecoder *decoder);
const char *mvc_error(MVCDecoder *decoder);
int mvc_saw_stereo(MVCDecoder *decoder);
int mvc_selected_audio(MVCDecoder *decoder);
void mvc_close(MVCDecoder *decoder);

// Packet adapter used by the player and the integration tests. No NAL reordering.
typedef int (*MVCNALCallback)(void *, const uint8_t *, size_t);
int mvc_visit_nals(const uint8_t *data, size_t size, int length_size, MVCNALCallback visit, void *ctx);
const char *mvc_versions(void);
int mvc_copy_nv12(const uint8_t *y, const uint8_t *u, const uint8_t *v,
    int width, int height, int y_stride, int c_stride,
    uint8_t *out_y, uint8_t *out_uv, int out_y_stride, int out_uv_stride);
#ifdef __cplusplus
}
#endif
#endif
