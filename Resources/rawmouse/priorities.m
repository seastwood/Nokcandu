// Who gets the CPU while you play.
//
// - The game's own process asks for the "user interactive" quality of service on its main thread (threads it
//   starts inherit it), so macOS keeps it on the performance cores; Rosetta-translated games otherwise sometimes
//   land on efficiency cores and stutter.
// - While a game is in front it says so (~/Library/Application Support/Nokcandu/game-in-front, its process id).
//   Store clients running beside it (Steam, its web helper, Battle.net, the EA app, Ubisoft Connect…) check every
//   two seconds and run as background work while it is: they keep working (downloads, sign-in, friends) but stop
//   competing with the game. When you switch to them, or the game quits, they're back to normal.
//   The client the game itself belongs to (same Wine environment) is left alone: see launcher-priority.h.
//   Turned off by creating ~/Library/Application Support/Nokcandu/launchers-normal-priority.
#import <AppKit/AppKit.h>
#include <sys/resource.h>
#include <pthread/qos.h>
#include "launcher-priority.h"

static char prio_flag_path[PATH_MAX], prio_off_path[PATH_MAX];

static void prio_paths(void) {
    const char *home = getenv("HOME");
    if (!home || prio_flag_path[0]) return;
    snprintf(prio_flag_path, sizeof prio_flag_path, "%s/Library/Application Support/Nokcandu/game-in-front", home);
    snprintf(prio_off_path, sizeof prio_off_path, "%s/Library/Application Support/Nokcandu/launchers-normal-priority", home);
}

static bool launcher_program(const char *path) {
    if (!path) return false;
    const char *name = path;
    for (const char *p = path; *p; ++p) if (*p == '/' || *p == '\\') name = p + 1;
    static const char *names[] = {
        "steam.exe", "steamwebhelper.exe", "steamservice.exe", "battle.net.exe", "agent.exe", "blizzard battle.net app.exe",
        "battle.net launcher.exe", "eadesktop.exe", "eabackgroundservice.exe", "eacefsubprocess.exe", "ealocalhostsvc.exe",
        "upc.exe", "uplaywebcore.exe", "uplayservice.exe", "ubisoftconnect.exe", "galaxyclient.exe", "galaxyclient helper.exe",
        "epicgameslauncher.exe", "epicwebhelper.exe", NULL
    };
    for (unsigned i = 0; names[i]; ++i) if (!strcasecmp(name, names[i])) return true;
    return false;
}

#include <crt_externs.h>
static bool this_is_launcher(void) {
    int argc = *_NSGetArgc(); char **argv = *_NSGetArgv();
    return argc > 1 && launcher_program(argv[1]);
}

/// The game's process: performance cores for its threads.
static void prio_game_process(void) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
}

/// The game's process, once Cocoa runs: say while it's in front.
static void prio_watch_game_front(void) {
    prio_paths();
    if (!prio_flag_path[0]) return;
    void (^front)(BOOL) = ^(BOOL on) {
        if (on) {
            FILE *f = fopen(prio_flag_path, "w");
            const char *prefix = getenv("WINEPREFIX");
            if (f) { fprintf(f, "%d\n%s\n", getpid(), prefix ? prefix : ""); fclose(f); }
        } else {
            FILE *f = fopen(prio_flag_path, "r"); int pid = 0;
            if (f) { if (fscanf(f, "%d", &pid) != 1) pid = 0; fclose(f); }
            if (pid == getpid()) unlink(prio_flag_path);
        }
    };
    // Checked once a second (a game in a full-screen Space doesn't always get the resign notification).
    __block int last = -1;
    NSTimer *t = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) {
        int now = NSApp.isActive ? 1 : 0;
        if (now != last) { last = now; front(now); }
    }];
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
    atexit_b(^{ front(NO); });
}

/// A store client's process: background priority while a game is in front.
static void prio_watch_as_launcher(void) {
    prio_paths();
    if (!prio_flag_path[0]) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    __block bool background = false;
    dispatch_source_set_event_handler(t, ^{
        bool want = false;
        if (access(prio_off_path, F_OK) != 0) {
            char text[PATH_MAX + 32] = "", game_prefix[PATH_MAX];
            FILE *f = fopen(prio_flag_path, "r");
            if (f) { size_t n = fread(text, 1, sizeof text - 1, f); text[n] = 0; fclose(f); }
            int pid = nokcandu_front_game(text, game_prefix, sizeof game_prefix);
            // The game's own client (same Wine environment) stays at normal priority: the game waits on it.
            want = nokcandu_launcher_steps_back(pid > 1 && pid != getpid() && kill(pid, 0) == 0, game_prefix, getenv("WINEPREFIX"));
        }
        if (want != background && setpriority(PRIO_DARWIN_PROCESS, 0, want ? PRIO_DARWIN_BG : 0) == 0) background = want;
    });
    dispatch_resume(t);
    (void)CFBridgingRetain(t);
}
