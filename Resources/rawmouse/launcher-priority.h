// Which store clients step back while a game is in front.
//
// A client running as background work (PRIO_DARWIN_BG) gets little CPU, and macOS also throttles its disk
// and network. That is right for an unrelated client idling beside the game. It is wrong for the client the
// game belongs to: a Steam or Battle.net game talks to its client all through an online match (sign-in,
// matchmaking, the game coordinator, friends, voice), and waits on it. The game therefore says which Wine
// environment it runs in, and a client in that same environment keeps its normal priority.
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>

// The flag file's text: the game's process id on the first line, then (newer helpers) its Wine environment.
static int nokcandu_front_game(const char *text, char *environment, size_t size) {
    if (environment && size) environment[0] = 0;
    if (!text) return 0;
    char *end = NULL;
    long pid = strtol(text, &end, 10);
    if (end == text || pid <= 1 || pid > 0x7fffffff) return 0;
    if (environment && size && *end == '\n') {
        const char *line = end + 1; size_t n = strcspn(line, "\n");
        if (n >= size) n = size - 1;
        memcpy(environment, line, n); environment[n] = 0;
    }
    return (int)pid;
}

// Should this client run as background work? `game_alive`: the flagged game process exists and isn't us.
static bool nokcandu_launcher_steps_back(bool game_alive, const char *game_environment, const char *my_environment) {
    if (!game_alive) return false;
    if (game_environment && my_environment && game_environment[0] && !strcmp(game_environment, my_environment)) return false;
    return true;
}
