#ifndef SC_INTEROP_VIDEOTOOLBOX_H
#define SC_INTEROP_VIDEOTOOLBOX_H

#include "common.h"

#include <SDL3/SDL.h>
#include <libavutil/pixfmt.h>

#include "interop.h"

struct sc_interop_videotoolbox {
    struct sc_interop interop; // interop trait

    SDL_Renderer *renderer; // owned by the screen

    // LANADB: remember the last specified colour description so P-frames that
    // omit VUI tags do not flip between BT.601 and BT.709 / limited and full.
    enum AVColorSpace color_space;
    enum AVColorRange color_range;

    // The texture wraps the CVPixelBuffer of one frame, so a new texture is
    // created for every frame
};

struct sc_interop_videotoolbox *
sc_interop_videotoolbox_new(SDL_Renderer *renderer);

#endif
