#include "lanadb_record.h"

#include <stdlib.h>
#include <libavcodec/avcodec.h>

#include "recorder.h"
#include "util/log.h"
#include "util/thread.h"

#include "controller.h"

static struct {
    struct sc_packet_sink sink;
    bool initialized;
    sc_mutex mutex;
    AVCodecParameters *params;
    struct sc_stream_session session;
    struct sc_recorder *recorder;
    bool opened;           // the recorder's sink has been opened
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
            }
        } else if (state.waiting_key) {
            if (config) {
                // A newer configuration before the key frame replaces it.
                target->ops->push(target, packet);
            } else if (packet->flags & AV_PKT_FLAG_KEY) {
                state.waiting_key = false;
                target->ops->push(target, packet);
            }
        } else if (!config) {
            target->ops->push(target, packet);
        }
    }
    sc_mutex_unlock(&state.mutex);
    return SC_SINK_OK;
}

struct sc_packet_sink *
lanadb_record_sink(void) {
    if (!state.initialized) {
        static const struct sc_packet_sink_ops ops = {
            .open = sink_open,
            .close = sink_close,
            .push = sink_push,
        };
        state.sink.ops = &ops;
        if (!sc_mutex_init(&state.mutex)) {
            return NULL;
        }
        state.initialized = true;
    }
    return &state.sink;
}

bool
lanadb_record_start(const char *filename, int format) {
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
    struct sc_recorder *recorder = calloc(1, sizeof(*recorder));
    static const struct sc_recorder_callbacks cbs = { .on_ended = on_ended };
    if (!recorder || !sc_recorder_init(recorder, filename, (enum sc_record_format) format,
                                       true, false,
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
    state.recorder = NULL;
    state.opened = false;
    sc_mutex_unlock(&state.mutex);
    if (!recorder) {
        return false;
    }
    if (opened) {
        recorder->video_packet_sink.ops->close(&recorder->video_packet_sink);
    } else {
        sc_recorder_stop(recorder);
    }
    sc_recorder_join(recorder);
    sc_recorder_destroy(recorder);
    free(recorder);
    return opened && state.ended_ok;
}
