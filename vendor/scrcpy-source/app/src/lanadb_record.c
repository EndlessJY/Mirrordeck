#include "lanadb_record.h"

#include <stdlib.h>
#include <libavcodec/avcodec.h>

#include "recorder.h"
#include "util/log.h"
#include "util/thread.h"

#include "controller.h"

static struct {
    struct sc_packet_sink sink;
    struct sc_packet_sink audio_sink;
    bool initialized;
    sc_mutex mutex;
    AVCodecParameters *params;
    struct sc_stream_session session;
    AVCodecParameters *audio_params;
    struct sc_stream_session audio_session;
    AVPacket *audio_config;
    bool audio_available;
    struct sc_recorder *recorder;
    bool opened;           // the recorder's video sink has been opened
    bool audio_opened;     // the recorder's audio sink has been opened
    bool use_audio;
    bool waiting_config;   // waiting for the codec config packet
    bool waiting_key;      // waiting for the first key frame
    bool ended_ok;
} state;

static void
on_ended(struct sc_recorder *recorder, bool success, void *userdata) {
    (void) recorder;
    (void) userdata;
    state.ended_ok = success;
}

static bool
ensure_initialized(void) {
    if (!state.initialized) {
        if (!sc_mutex_init(&state.mutex)) {
            return false;
        }
        state.initialized = true;
    }
    return true;
}

static bool
sink_open(struct sc_packet_sink *sink, const AVCodecParameters *params,
          const struct sc_stream_session *session) {
    (void) sink;
    sc_mutex_lock(&state.mutex);
    if (!state.params) {
        state.params = avcodec_parameters_alloc();
    }
    bool ok = state.params && avcodec_parameters_copy(state.params, params) >= 0;
    if (session) {
        state.session = *session;
    }
    sc_mutex_unlock(&state.mutex);
    return ok;
}

static void
sink_close(struct sc_packet_sink *sink) {
    (void) sink;
    sc_mutex_lock(&state.mutex);
    if (state.recorder && state.opened) {
        state.recorder->video_packet_sink.ops->close(&state.recorder->video_packet_sink);
        state.opened = false;
    }
    sc_mutex_unlock(&state.mutex);
}

static enum sc_sink_result
sink_push(struct sc_packet_sink *sink, const AVPacket *packet) {
    (void) sink;
    sc_mutex_lock(&state.mutex);
    struct sc_recorder *recorder = state.recorder;
    if (recorder) {
        struct sc_packet_sink *target = &recorder->video_packet_sink;
        bool config = packet->pts == AV_NOPTS_VALUE;
        if (state.waiting_config) {
            if (config && target->ops->open(target, state.params, &state.session)) {
                state.opened = true;
                state.waiting_config = false;
                state.waiting_key = true;
                target->ops->push(target, packet);
                if (state.use_audio && !state.audio_opened && state.audio_available
                        && state.audio_params) {
                    struct sc_packet_sink *atarget = &recorder->audio_packet_sink;
                    if (atarget->ops->open(atarget, state.audio_params, &state.audio_session)) {
                        state.audio_opened = true;
                        if (state.audio_config) {
                            atarget->ops->push(atarget, state.audio_config);
                        }
                    } else if (atarget->ops->disable) {
                        atarget->ops->disable(atarget);
                        state.use_audio = false;
                    }
                }
            }
        } else if (state.waiting_key) {
            if (!config && (packet->flags & AV_PKT_FLAG_KEY)) {
                state.waiting_key = false;
                target->ops->push(target, packet);
            }
        } else {
            target->ops->push(target, packet);
        }
    }
    sc_mutex_unlock(&state.mutex);
    return SC_SINK_OK;
}

static bool
audio_sink_open(struct sc_packet_sink *sink, const AVCodecParameters *params,
                const struct sc_stream_session *session) {
    (void) sink;
    sc_mutex_lock(&state.mutex);
    if (!state.audio_params) {
        state.audio_params = avcodec_parameters_alloc();
    }
    bool ok = state.audio_params
        && avcodec_parameters_copy(state.audio_params, params) >= 0;
    if (session) {
        state.audio_session = *session;
    }
    av_packet_free(&state.audio_config);
    state.audio_available = ok;
    sc_mutex_unlock(&state.mutex);
    return ok;
}

static void
audio_sink_close(struct sc_packet_sink *sink) {
    (void) sink;
    sc_mutex_lock(&state.mutex);
    state.audio_available = false;
    av_packet_free(&state.audio_config);
    if (state.recorder) {
        if (state.audio_opened) {
            state.recorder->audio_packet_sink.ops->close(
                &state.recorder->audio_packet_sink);
            state.audio_opened = false;
        } else if (state.use_audio
                && state.recorder->audio_packet_sink.ops->disable) {
            state.recorder->audio_packet_sink.ops->disable(
                &state.recorder->audio_packet_sink);
            state.use_audio = false;
        }
    }
    sc_mutex_unlock(&state.mutex);
}

static void
audio_sink_disable(struct sc_packet_sink *sink) {
    audio_sink_close(sink);
}

static enum sc_sink_result
audio_sink_push(struct sc_packet_sink *sink, const AVPacket *packet) {
    (void) sink;
    sc_mutex_lock(&state.mutex);
    if (packet->pts == AV_NOPTS_VALUE) {
        AVPacket *copy = av_packet_clone(packet);
        if (copy) {
            av_packet_free(&state.audio_config);
            state.audio_config = copy;
        }
    } else if (state.recorder && state.audio_opened && !state.waiting_key) {
        state.recorder->audio_packet_sink.ops->push(
            &state.recorder->audio_packet_sink, packet);
    }
    sc_mutex_unlock(&state.mutex);
    return SC_SINK_OK;
}

static enum sc_sink_result
sink_push_session(struct sc_packet_sink *sink,
                  const struct sc_stream_session *session) {
    (void) sink;
    if (!session) {
        return SC_SINK_OK;
    }
    sc_mutex_lock(&state.mutex);
    state.session = *session;
    if (state.params && session->video.width && session->video.height) {
        state.params->width = session->video.width;
        state.params->height = session->video.height;
    }
    sc_mutex_unlock(&state.mutex);
    return SC_SINK_OK;
}

struct sc_packet_sink *
lanadb_record_sink(void) {
    if (!ensure_initialized()) {
        return NULL;
    }
    static const struct sc_packet_sink_ops ops = {
        .open = sink_open,
        .close = sink_close,
        .push = sink_push,
        .push_session = sink_push_session,
    };
    state.sink.ops = &ops;
    return &state.sink;
}

struct sc_packet_sink *
lanadb_record_audio_sink(void) {
    if (!ensure_initialized()) {
        return NULL;
    }
    static const struct sc_packet_sink_ops ops = {
        .open = audio_sink_open,
        .close = audio_sink_close,
        .push = audio_sink_push,
        .disable = audio_sink_disable,
    };
    state.audio_sink.ops = &ops;
    return &state.audio_sink;
}

bool
lanadb_record_start(const char *filename, int format, bool audio) {
    _Static_assert(SC_RECORD_FORMAT_MP4 == 1 && SC_RECORD_FORMAT_MKV == 2,
                   "the title bar passes these values");
    if (!state.initialized) {
        return false;
    }
    sc_mutex_lock(&state.mutex);
    if (state.recorder || !state.params) {
        sc_mutex_unlock(&state.mutex);
        return false;
    }
    bool expects_audio_cfg = state.audio_params
        && state.audio_params->codec_id != AV_CODEC_ID_PCM_S16LE;
    bool use_audio = audio && state.audio_available && state.audio_params
        && (!expects_audio_cfg || state.audio_config != NULL);
    struct sc_recorder *recorder = calloc(1, sizeof(*recorder));
    static const struct sc_recorder_callbacks cbs = { .on_ended = on_ended };
    if (!recorder || !sc_recorder_init(recorder, filename, (enum sc_record_format) format,
                                       true, use_audio,
                                       SC_ORIENTATION_0, &cbs, NULL)) {
        free(recorder);
        sc_mutex_unlock(&state.mutex);
        return false;
    }
    if (!sc_recorder_start(recorder)) {
        sc_recorder_destroy(recorder);
        free(recorder);
        sc_mutex_unlock(&state.mutex);
        return false;
    }
    state.recorder = recorder;
    state.opened = false;
    state.audio_opened = false;
    state.use_audio = use_audio;
    state.waiting_config = true;
    state.waiting_key = false;
    state.ended_ok = false;
    sc_mutex_unlock(&state.mutex);
    // A new encoder session sends its config packet and a key frame at once.
    sc_lanadb_reset_video();
    return true;
}

bool
lanadb_record_stop(void) {
    if (!state.initialized) {
        return false;
    }
    sc_mutex_lock(&state.mutex);
    struct sc_recorder *recorder = state.recorder;
    bool opened = state.opened;
    bool audio_opened = state.audio_opened;
    state.recorder = NULL;
    state.opened = false;
    state.audio_opened = false;
    state.use_audio = false;
    sc_mutex_unlock(&state.mutex);
    if (!recorder) {
        return false;
    }
    if (opened) {
        recorder->video_packet_sink.ops->close(&recorder->video_packet_sink);
    }
    if (audio_opened) {
        recorder->audio_packet_sink.ops->close(&recorder->audio_packet_sink);
    }
    if (!opened && !audio_opened) {
        sc_recorder_stop(recorder);
    }
    sc_recorder_join(recorder);
    sc_recorder_destroy(recorder);
    free(recorder);
    return opened && state.ended_ok;
}
