#ifndef SC_MACOS_TITLEBAR_H
#define SC_MACOS_TITLEBAR_H

#include <SDL3/SDL.h>

// Add controls to scrcpy's own Cocoa window. Enabled only for LAN ADB Manager.
void
sc_macos_titlebar_install(SDL_Window *window);

#endif
