#ifndef SC_AUDIO_PLAYER_H
#define SC_AUDIO_PLAYER_H

#include "common.h"

#include <SDL3/SDL_audio.h>

#include "audio_regulator.h"
#include "trait/frame_sink.h"
#include "util/tick.h"

struct sc_audio_player {
    struct sc_frame_sink frame_sink;

    // The target buffering between the producer and the consumer. This value
    // is directly use for compensation.
    // Since audio capture and/or encoding on the device typically produce
    // blocks of 960 samples (20ms) or 1024 samples (~21.3ms), this target
    // value should be higher.
    sc_tick target_buffering_delay;

    // SDL audio output buffer size
    sc_tick output_buffer_duration;

    uint8_t *aout_buffer;
    size_t aout_buffer_size;

    SDL_AudioStream *stream;
    SDL_AudioDeviceID device; // owned by the audio stream
    struct sc_audio_regulator audioreg;
};

void
sc_audio_player_init(struct sc_audio_player *ap, sc_tick target_buffering,
                     sc_tick audio_output_buffer);

// Control only this scrcpy instance's playback, independent of OEM ADB volume handling.
void sc_audio_player_set_muted(bool muted);
bool sc_audio_player_is_muted(void);

// LANADB: a single-app window captures only its app's sound, before the
// phone's volume applies, so its volume steps act on this window's playback
// instead (level 0...10). True when that is the case.
bool sc_audio_player_local_volume(void);
// Moves the level by `delta` steps; returns the new level.
int sc_audio_player_step_volume(int delta);

#endif
