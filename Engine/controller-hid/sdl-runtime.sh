#!/bin/bash
# Sikarugir's original Wine 11 bus uses its versioned SDL2 compatibility runtime.
# The same Frameworks folder also contains an unrelated old libSDL2.dylib.
# Do not silently substitute it: enumeration and backend support differ.
nokcandu_controller_sdl_runtime() {
    local sdlFolder="$1"
    NOKCANDU_CONTROLLER_SDL_NAME=libSDL2-2.0.0.dylib
    local sdlFile="$sdlFolder/$NOKCANDU_CONTROLLER_SDL_NAME"
    [ -f "$sdlFile" ] || { echo 'The engine SDL2 compatibility runtime is missing; refusing the older fallback.' >&2; return 1; }
    /usr/bin/otool -D "$sdlFile" | /usr/bin/tail -1 | /usr/bin/grep -Eq '(^|/)libSDL2-2\.0\.0\.dylib$' || {
        echo 'The SDL2 compatibility runtime has an unexpected install name.' >&2; return 1;
    }
    export NOKCANDU_CONTROLLER_SDL_NAME
}
