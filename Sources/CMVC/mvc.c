#include "CMVC.h"
#include "edge264mvc.h"
#include "audio_clock.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/avutil.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <math.h>

struct MVCDecoder {
    MVCIO input; MVCCallbacks callbacks;
    AVFormatContext *format; AVIOContext *avio;
    Edge264MvcDecoder *video;
    AVCodecContext *audio; SwrContext *swr; AVChannelLayout swr_layout;
    int swr_format, swr_rate;
    AVPacket *packet; AVFrame *audio_frame;
    MVCMediaInfo info;
    int video_index, audio_index, length_size, stereo, saw_mvc, drained, submitted;
    int64_t position, origin_us, target_us;
    MVCAudioClock audio_clock;
    atomic_bool cancelled;
    char error[512];
};
static const AVRational US = {1, 1000000};

static int fail(MVCDecoder *d, const char *message, int code) {
    char detail[128] = "";
    if (code < 0) av_strerror(code, detail, sizeof(detail));
    snprintf(d->error, sizeof(d->error), "%s%s%s", message, code < 0 ? ": " : "", detail);
    return atomic_load(&d->cancelled) ? -2 : -1;
}
static int interrupted(void *ctx) { return atomic_load(&((MVCDecoder *)ctx)->cancelled); }
static int read_packet(void *ctx, uint8_t *buffer, int count) {
    MVCDecoder *d = ctx;
    if (interrupted(d)) return AVERROR_EXIT;
    int result = d->input.read_at(d->input.context, d->position, buffer, count);
    if (result < 0) return interrupted(d) ? AVERROR_EXIT : AVERROR(EIO);
    if (!result) return AVERROR_EOF;
    if (result > count) return AVERROR(EIO);
    d->position += result;
    return result;
}
static int64_t seek_io(void *ctx, int64_t offset, int whence) {
    MVCDecoder *d = ctx;
    if (whence == AVSEEK_SIZE) return d->input.size;
    whence &= ~AVSEEK_FORCE;
    int64_t base = whence == SEEK_SET ? 0 : whence == SEEK_CUR ? d->position : whence == SEEK_END ? d->input.size : -1;
    if (base < 0 || (offset > 0 && base > INT64_MAX - offset) || (offset < 0 && offset < -base)) return AVERROR(EINVAL);
    int64_t destination = base + offset;
    if (destination < 0 || destination > d->input.size) return AVERROR(EINVAL);
    d->position = destination;
    return destination;
}
static size_t start_code(const uint8_t *p, size_t n, size_t *prefix) {
    for (size_t i = 0; i + 2 < n; ++i) {
        if (p[i] == 0 && p[i+1] == 0) {
            if (p[i+2] == 1) { *prefix = 3; return i; }
            if (i + 3 < n && p[i+2] == 0 && p[i+3] == 1) { *prefix = 4; return i; }
        }
    }
    return n;
}
int mvc_visit_nals(const uint8_t *data, size_t size, int length_size, MVCNALCallback visit, void *ctx) {
    if (!data || !visit || size > (64u << 20)) return -1;
    if (length_size) {
        if (length_size < 1 || length_size > 4 || length_size == 3) return -1;
        size_t position = 0;
        while (position < size) {
            if (size - position < (size_t)length_size) return -1;
            uint32_t length = 0;
            for (int j = 0; j < length_size; j++) length = (length << 8) | data[position++];
            if (!length || length > size - position) return -1;
            int result = visit(ctx, data + position, length);
            if (result) return result;
            position += length;
        }
    } else {
        size_t prefix = 0, position = start_code(data, size, &prefix);
        if (position == size) return -1;
        while (position < size) {
            size_t begin = position + prefix, next_prefix = 0;
            size_t next = begin + start_code(data + begin, size - begin, &next_prefix);
            size_t end = next;
            while (end > begin && data[end - 1] == 0) end--;
            if (end > begin) {
                int result = visit(ctx, data + begin, end - begin);
                if (result) return result;
            }
            position = next; prefix = next_prefix;
        }
    }
    return 0;
}

static int receive_video(MVCDecoder *d) {
    Edge264MvcFrame f;
    int result;
    while ((result = edge264mvc_receive_frame(d->video, &f)) == EDGE264MVC_OK) {
        int status = 0;
        if (interrupted(d)) status = -2;
        else if (!f.views[0].planes[0] || !f.views[1].planes[0]) {
            status = fail(d, "MVC stereo is unavailable: dependent MVC view missing", 0);
        } else if (f.bit_depth_Y != 8 || f.bit_depth_C != 8 || f.width_C != (f.width_Y + 1)/2 || f.height_C != (f.height_Y + 1)/2) {
            status = fail(d, "MVC playback supports 8-bit 4:2:0 only", 0);
        } else {
            d->stereo = 1;
            if (f.views[0].pts == AV_NOPTS_VALUE || f.views[1].pts != f.views[0].pts) {
                status = fail(d, "MVC eye timestamps are missing or disagree", 0);
            } else if (f.views[0].pts >= d->target_us) {
                MVCVideoFrame out = {
                    .base_y = f.views[0].planes[0], .base_u = f.views[0].planes[1], .base_v = f.views[0].planes[2],
                    .dependent_y = f.views[1].planes[0], .dependent_u = f.views[1].planes[1], .dependent_v = f.views[1].planes[2],
                    .width = f.width_Y, .height = f.height_Y, .chroma_width = f.width_C, .chroma_height = f.height_C,
                    .stride_y = f.stride_Y, .stride_c = f.stride_C, .pts_us = f.views[0].pts,
                    .duration_us = f.views[0].user_data, .display_order = f.views[0].display_order,
                    .flags = f.views[0].flags | f.views[1].flags
                };
                if (d->callbacks.video && !d->callbacks.video(d->callbacks.context, &out)) status = -2;
            }
        }
        edge264mvc_release_frame(d->video, &f);
        if (status) return status;
    }
    return result == EDGE264MVC_AGAIN || result == EDGE264MVC_END ? 0 : fail(d, "MVC receive failed", 0);
}
static int send_nal(MVCDecoder *d, const uint8_t *nal, size_t size, int64_t pts, int64_t duration) {
    int type = nal[0] & 31;
    if (type == 15 || type == 20) d->saw_mvc = 1;
    int result;
    while ((result = edge264mvc_send_nal(d->video, nal, size, pts, duration)) == EDGE264MVC_AGAIN) {
        int r = receive_video(d);
        if (r) return r;
        if (interrupted(d)) return -2;
    }
    // Unspecified units carried by Blu-rays are harmless. Unsupported coded pictures are not.
    if (result == EDGE264MVC_UNSUPPORTED && type >= 24) return 0;
    if (result == EDGE264MVC_CORRUPT) return fail(d, "Corrupt MVC NAL; stereo integrity cannot be guaranteed", 0);
    if (result < 0) return fail(d, "Unsupported or invalid MVC NAL", 0);
    return receive_video(d);
}
typedef struct { MVCDecoder *d; int64_t pts, duration; } NALContext;
static int visit_nal(void *ctx, const uint8_t *nal, size_t size) {
    NALContext *n = ctx;
    return send_nal(n->d, nal, size, n->pts, n->duration);
}
static int codec_private(MVCDecoder *d) {
    AVCodecParameters *p = d->format->streams[d->video_index]->codecpar;
    const uint8_t *data = p->extradata;
    size_t size = p->extradata_size;
    if (!size) return 0;
    NALContext context = {d, AV_NOPTS_VALUE, 0};
    if (data[0] != 1) {
        d->length_size = 0;
        return mvc_visit_nals(data, size, 0, visit_nal, &context);
    }
    if (size < 7) return fail(d, "Truncated AVC configuration", 0);
    d->length_size = (data[4] & 3) + 1;
    if (d->length_size == 3) return fail(d, "Invalid AVC NAL length size", 0);
    size_t position = 6;
    int counts[3] = {data[5] & 31, 0, 0};
    for (int group = 0; group < 3; group++) {
        if (group == 1) {
            if (position >= size) return fail(d, "Missing AVC PPS count", 0);
            counts[1] = data[position++];
        } else if (group == 2) {
            if (position == size) break;
            if (size - position < 4) return fail(d, "Truncated AVC configuration extension", 0);
            position += 3; counts[2] = data[position++];
        }
        for (int i = 0; i < counts[group]; i++) {
            if (size - position < 2) return fail(d, "Truncated AVC parameter length", 0);
            size_t n = ((size_t)data[position] << 8) | data[position+1]; position += 2;
            if (!n || n > size - position) return fail(d, "Truncated AVC parameter data", 0);
            int r = send_nal(d, data + position, n, AV_NOPTS_VALUE, 0);
            if (r) return r;
            position += n;
        }
    }
    return 0;
}
static MVCChannel map_channel(enum AVChannel c) {
    switch (c) {
        case AV_CHAN_FRONT_LEFT: return MVC_CH_LEFT;
        case AV_CHAN_FRONT_RIGHT: return MVC_CH_RIGHT;
        case AV_CHAN_FRONT_CENTER: return MVC_CH_CENTER;
        case AV_CHAN_LOW_FREQUENCY: return MVC_CH_LFE;
        case AV_CHAN_BACK_LEFT: return MVC_CH_BACK_LEFT;
        case AV_CHAN_BACK_RIGHT: return MVC_CH_BACK_RIGHT;
        case AV_CHAN_SIDE_LEFT: return MVC_CH_SIDE_LEFT;
        case AV_CHAN_SIDE_RIGHT: return MVC_CH_SIDE_RIGHT;
        case AV_CHAN_BACK_CENTER: return MVC_CH_BACK_CENTER;
        default: return MVC_CH_UNKNOWN;
    }
}
static int open_audio(MVCDecoder *d, int stream) {
    avcodec_free_context(&d->audio);
    swr_free(&d->swr); av_channel_layout_uninit(&d->swr_layout);
    d->audio_index = stream; d->audio_clock = (MVCAudioClock){0};
    if (stream < 0) return 0;
    if (stream >= (int)d->format->nb_streams || d->format->streams[stream]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO)
        return fail(d, "Invalid audio selection", 0);
    AVCodecParameters *p = d->format->streams[stream]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(p->codec_id);
    if (!codec) return fail(d, "Selected audio codec was not built", 0);
    d->audio = avcodec_alloc_context3(codec);
    if (!d->audio) return fail(d, "Cannot allocate audio decoder", 0);
    int r = avcodec_parameters_to_context(d->audio, p);
    if (r < 0) return fail(d, "Cannot configure audio decoder", r);
    d->audio->pkt_timebase = d->format->streams[stream]->time_base;
    r = avcodec_open2(d->audio, codec, NULL);
    return r < 0 ? fail(d, "Cannot open audio decoder", r) : 0;
}
static int receive_audio(MVCDecoder *d) {
    int r;
    AVFrame *f = d->audio_frame;
    while ((r = avcodec_receive_frame(d->audio, f)) >= 0) {
        int channels = f->ch_layout.nb_channels;
        if (channels < 1 || channels > 8 || f->sample_rate <= 0) return fail(d, "Unsupported audio layout (maximum 7.1)", 0);
        MVCAudioFrame out = {.sample_rate = f->sample_rate, .channels = channels};
        for (int i = 0; i < channels; i++) {
            out.channel_ids[i] = map_channel(av_channel_layout_channel_from_index(&f->ch_layout, i));
            if (!out.channel_ids[i]) return fail(d, "Audio has unknown channel labels; refusing to guess", 0);
        }
        if (!d->swr || d->swr_format != f->format || d->swr_rate != f->sample_rate || av_channel_layout_compare(&d->swr_layout, &f->ch_layout)) {
            swr_free(&d->swr); av_channel_layout_uninit(&d->swr_layout);
            r = swr_alloc_set_opts2(&d->swr, &f->ch_layout, AV_SAMPLE_FMT_FLT, f->sample_rate,
                                   &f->ch_layout, f->format, f->sample_rate, 0, NULL);
            if (r < 0 || swr_init(d->swr) < 0) return fail(d, "Cannot configure multichannel PCM", r);
            av_channel_layout_copy(&d->swr_layout, &f->ch_layout);
            d->swr_format = f->format; d->swr_rate = f->sample_rate;
        }
        int capacity = swr_get_out_samples(d->swr, f->nb_samples);
        uint8_t *pcm = av_malloc_array((size_t)capacity * channels, sizeof(float));
        if (!pcm) return fail(d, "Cannot allocate PCM", 0);
        int samples = swr_convert(d->swr, &pcm, capacity, (const uint8_t **)f->extended_data, f->nb_samples);
        if (samples < 0) { av_free(pcm); return fail(d, "PCM conversion failed", samples); }
        int64_t timestamp = f->best_effort_timestamp;
        AVRational timebase = d->format->streams[d->audio_index]->time_base;
        int64_t source_pts = timestamp == AV_NOPTS_VALUE ? AV_NOPTS_VALUE : av_rescale_q(timestamp, timebase, US) - d->origin_us;
        int64_t tolerance = FFMAX(2000, av_rescale_q(2, timebase, US));
        int64_t pts = mvc_audio_clock_push(&d->audio_clock, source_pts, samples, f->sample_rate, tolerance);
        if (pts == AV_NOPTS_VALUE) { av_free(pcm); return fail(d, "Audio timestamps missing", 0); }
        int skip = pts < d->target_us ? (int)FFMIN(samples, av_rescale_rnd(d->target_us - pts, f->sample_rate, 1000000, AV_ROUND_UP)) : 0;
        out.samples = (float *)pcm + skip * channels;
        out.sample_count = samples - skip;
        out.pts_us = pts + av_rescale(skip, 1000000, f->sample_rate);
        int ok = interrupted(d) ? 0 : !out.sample_count || !d->callbacks.audio || d->callbacks.audio(d->callbacks.context, &out);
        av_free(pcm); av_frame_unref(f);
        if (!ok) return -2;
    }
    return r == AVERROR(EAGAIN) || r == AVERROR_EOF ? 0 : fail(d, "Audio decode failed", r);
}

MVCDecoder *mvc_create(MVCIO io, MVCCallbacks callbacks, int threads) {
    if (!io.read_at || io.size <= 0 || threads < 1 || threads > 16) return NULL;
    MVCDecoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->input = io; d->callbacks = callbacks; d->video_index = -1; d->audio_index = -1;
    d->length_size = 4; atomic_init(&d->cancelled, 0);
    Edge264MvcSettings settings; edge264mvc_default_settings(&settings);
    settings.n_threads = threads; settings.max_frame_pixels = 1920 * 1088;
    if (edge264mvc_open(&d->video, &settings) != EDGE264MVC_OK) { free(d); return NULL; }
    return d;
}
int mvc_open(MVCDecoder *d) {
    d->format = avformat_alloc_context();
    uint8_t *buffer = av_malloc(256 * 1024);
    if (!d->format || !buffer) { av_free(buffer); return fail(d, "Cannot allocate demuxer", 0); }
    d->avio = avio_alloc_context(buffer, 256 * 1024, 0, d, read_packet, NULL, seek_io);
    if (!d->avio) { av_free(buffer); return fail(d, "Cannot allocate AVIO", 0); }
    d->avio->seekable = AVIO_SEEKABLE_NORMAL;
    d->format->pb = d->avio; d->format->flags |= AVFMT_FLAG_CUSTOM_IO;
    d->format->interrupt_callback = (AVIOInterruptCB){interrupted, d};
    int r = avformat_open_input(&d->format, NULL, av_find_input_format("matroska"), NULL);
    if (r < 0) return fail(d, "Cannot open MKV", r);
    // Bound probing, especially when the file is on a network share.
    d->format->probesize = 8 << 20; d->format->max_analyze_duration = 2000000;
    r = avformat_find_stream_info(d->format, NULL);
    if (r < 0) return fail(d, "Cannot inspect MKV tracks", r);
    for (unsigned i = 0; i < d->format->nb_streams; i++) {
        AVStream *s = d->format->streams[i]; AVCodecParameters *p = s->codecpar;
        if (p->codec_type == AVMEDIA_TYPE_VIDEO && p->codec_id == AV_CODEC_ID_H264) {
            if (d->video_index >= 0) return fail(d, "Multiple AVC video tracks are outside this proof", 0);
            d->video_index = i;
        }
        if (p->codec_type == AVMEDIA_TYPE_AUDIO && d->info.audio_count < 32) {
            MVCAudioTrack *a = &d->info.audio[d->info.audio_count++];
            a->index = i; a->channels = p->ch_layout.nb_channels; a->sample_rate = p->sample_rate;
            snprintf(a->codec, sizeof(a->codec), "%s", avcodec_get_name(p->codec_id));
            AVDictionaryEntry *e = av_dict_get(s->metadata, "language", NULL, 0);
            if (e) snprintf(a->language, sizeof(a->language), "%s", e->value);
            e = av_dict_get(s->metadata, "title", NULL, 0);
            if (e) snprintf(a->title, sizeof(a->title), "%s", e->value);
        }
    }
    if (d->video_index < 0) return fail(d, "No AVC/MVC video track", 0);
    AVStream *s = d->format->streams[d->video_index]; AVCodecParameters *p = s->codecpar;
    d->info.width = p->width; d->info.height = p->height;
    if (p->width > 1920 || p->height > 1088) return fail(d, "MVC playback supports at most 1920x1088", 0);
    if (p->field_order != AV_FIELD_UNKNOWN && p->field_order != AV_FIELD_PROGRESSIVE) return fail(d, "Interlaced MVC is not supported", 0);
    d->info.full_range = p->color_range == AVCOL_RANGE_JPEG;
    d->info.color_primaries = p->color_primaries; d->info.color_transfer = p->color_trc; d->info.color_matrix = p->color_space;
    if (p->color_trc == AVCOL_TRC_SMPTE2084 || p->color_trc == AVCOL_TRC_ARIB_STD_B67) return fail(d, "HDR is outside this proof", 0);
    AVRational rate = av_guess_frame_rate(d->format, s, NULL);
    d->info.fps = rate.num && rate.den ? av_q2d(rate) : 24000.0/1001;
    d->info.sar_num = p->sample_aspect_ratio.num > 0 ? p->sample_aspect_ratio.num : 1;
    d->info.sar_den = p->sample_aspect_ratio.den > 0 ? p->sample_aspect_ratio.den : 1;
    d->origin_us = d->format->start_time != AV_NOPTS_VALUE ? d->format->start_time : s->start_time != AV_NOPTS_VALUE ? av_rescale_q(s->start_time, s->time_base, US) : 0;
    d->info.duration = d->format->duration != AV_NOPTS_VALUE ? d->format->duration / 1000000.0 : 0;
    AVDictionaryEntry *stereo = av_dict_get(s->metadata, "stereo_mode", NULL, 0);
    if (stereo && (strstr(stereo->value, "right_left") || strstr(stereo->value, "right_first") || !strcmp(stereo->value, "block_rl"))) d->info.base_is_right = 1;
    d->packet = av_packet_alloc(); d->audio_frame = av_frame_alloc();
    if (!d->packet || !d->audio_frame) return fail(d, "Cannot allocate decode buffers", 0);
    int audio_stream = -1;
    for (int i = 0; i < d->info.audio_count; i++) {
        int index = d->info.audio[i].index;
        if (audio_stream < 0 || (d->format->streams[index]->disposition & AV_DISPOSITION_DEFAULT)) audio_stream = index;
        if (d->format->streams[index]->disposition & AV_DISPOSITION_DEFAULT) break;
    }
    if (open_audio(d, audio_stream)) return -1;
    return codec_private(d);
}
const MVCMediaInfo *mvc_info(MVCDecoder *d) { return &d->info; }
int mvc_step(MVCDecoder *d) {
    if (interrupted(d)) return -2;
    if (d->drained) return 0;
    int r = av_read_frame(d->format, d->packet);
    if (r == AVERROR_EOF) {
        d->drained = 1;
        edge264mvc_send_end(d->video);
        int result = receive_video(d);
        if (result) return result;
        if (!d->stereo) return fail(d, "MVC stereo is unavailable: no complete stereo pairs decoded", 0);
        if (d->audio) {
            r = avcodec_send_packet(d->audio, NULL);
            if (r < 0 && r != AVERROR_EOF) return fail(d, "Cannot drain audio", r);
            result = receive_audio(d); if (result) return result;
        }
        return 0;
    }
    if (r < 0) return fail(d, "MKV read failed", r);
    int result = 0;
    AVPacket *packet = d->packet;
    if (packet->stream_index == d->video_index) {
        if (packet->pts == AV_NOPTS_VALUE) result = fail(d, "Video presentation timestamp missing", 0);
        else {
            AVStream *s = d->format->streams[d->video_index];
            NALContext n = {d, av_rescale_q(packet->pts, s->time_base, US) - d->origin_us,
                packet->duration > 0 ? av_rescale_q(packet->duration, s->time_base, US) : (int64_t)llround(1000000.0/d->info.fps)};
            result = mvc_visit_nals(packet->data, packet->size, d->length_size, visit_nal, &n);
            if (result == -1 && !d->error[0]) result = fail(d, "Malformed length-prefixed AVC packet", 0);
        }
    } else if (packet->stream_index == d->audio_index) {
        r = avcodec_send_packet(d->audio, packet);
        if (r == AVERROR(EAGAIN)) { result = receive_audio(d); if (!result) r = avcodec_send_packet(d->audio, packet); }
        if (!result) result = r < 0 ? fail(d, "Audio packet rejected", r) : receive_audio(d);
    }
    av_packet_unref(packet);
    return result ? result : 1;
}
int mvc_seek(MVCDecoder *d, int64_t target_us, int audio_stream_index) {
    d->error[0] = 0; d->drained = 0; d->submitted = 0; d->target_us = FFMAX(0, target_us);
    // Previous cancellation may have latched an AVIO error. Clear it before seeking.
    d->avio->error = 0; d->avio->eof_reached = 0;
    if (audio_stream_index != d->audio_index && open_audio(d, audio_stream_index)) return -1;
    int64_t timestamp = av_rescale_q(d->target_us + d->origin_us, US, d->format->streams[d->video_index]->time_base);
    int r = av_seek_frame(d->format, d->video_index, timestamp, AVSEEK_FLAG_BACKWARD);
    if (r < 0) return fail(d, "Cannot seek to preceding keyframe", r);
    avformat_flush(d->format); av_packet_unref(d->packet);
    edge264mvc_flush(d->video);
    if (d->audio) avcodec_flush_buffers(d->audio);
    swr_free(&d->swr); av_channel_layout_uninit(&d->swr_layout);
    d->audio_clock = (MVCAudioClock){0};
    return codec_private(d);
}
void mvc_cancel(MVCDecoder *d) { atomic_store(&d->cancelled, 1); }
void mvc_reset_cancel(MVCDecoder *d) { atomic_store(&d->cancelled, 0); }
const char *mvc_error(MVCDecoder *d) { return d->error; }
int mvc_saw_stereo(MVCDecoder *d) { return d->stereo; }
int mvc_selected_audio(MVCDecoder *d) { return d->audio_index; }
void mvc_close(MVCDecoder *d) {
    if (!d) return;
    av_packet_free(&d->packet); av_frame_free(&d->audio_frame);
    avcodec_free_context(&d->audio); swr_free(&d->swr); av_channel_layout_uninit(&d->swr_layout);
    avformat_close_input(&d->format);
    if (d->avio) { av_freep(&d->avio->buffer); avio_context_free(&d->avio); }
    edge264mvc_close(&d->video); free(d);
}
const char *mvc_versions(void) { return "FFmpeg " AV_STRINGIFY(LIBAVFORMAT_VERSION) "; edge264-mvc " AV_STRINGIFY(EDGE264MVC_API_VERSION_MAJOR) "." AV_STRINGIFY(EDGE264MVC_API_VERSION_MINOR); }
int mvc_copy_nv12(const uint8_t *y, const uint8_t *u, const uint8_t *v,
    int width, int height, int y_stride, int c_stride,
    uint8_t *out_y, uint8_t *out_uv, int out_y_stride, int out_uv_stride) {
    if (!y || !u || !v || !out_y || !out_uv || width < 1 || height < 1 || width > 1920 || height > 1088 ||
        y_stride < width || c_stride < (width+1)/2 || out_y_stride < width || out_uv_stride < ((width+1)/2)*2) return -1;
    for (int row = 0; row < height; row++) memcpy(out_y + row*out_y_stride, y + row*y_stride, width);
    for (int row = 0; row < (height+1)/2; row++) {
        uint8_t *destination = out_uv + row*out_uv_stride;
        const uint8_t *cb = u + row*c_stride, *cr = v + row*c_stride;
        for (int x = 0; x < (width+1)/2; x++) { destination[2*x] = cb[x]; destination[2*x+1] = cr[x]; }
    }
    return 0;
}
