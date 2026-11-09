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

// Starts writing the video to `filename` from the next key frame (a fresh one
// is requested from the device). Returns false if already recording.
bool
lanadb_record_start(const char *filename, int format);

// Stops and finalizes the file; blocks until it is written. Returns whether a
// complete file was written.
bool
lanadb_record_stop(void);

#endif
