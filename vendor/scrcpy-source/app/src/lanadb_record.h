#ifndef LANADB_RECORD_H
#define LANADB_RECORD_H

// LANADB: recording started and stopped while the window is open. Single-app
// windows show a virtual display that no other process may capture, so they
// record the stream this client already receives.

#include "common.h"

#include <stdbool.h>

#include "options.h"
#include "trait/packet_sink.h"

// The packet sink to attach to the video demuxer (always idle until started).
struct sc_packet_sink *
lanadb_record_sink(void);

// The packet sink to attach to the audio demuxer (caches codec config and
// forwards live audio while an audio-enabled recording is active).
struct sc_packet_sink *
lanadb_record_audio_sink(void);

// Starts writing the video (and live audio when `audio` is true and available)
// to `filename` from the next key frame. Returns false if already recording.
bool
lanadb_record_start(const char *filename, int format, bool audio);

// Stops and finalizes the file; blocks until it is written. Returns whether a
// complete file was written.
bool
lanadb_record_stop(void);

#endif
