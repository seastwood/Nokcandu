// Per-game key remapping. While one of this game's windows is in front, the keys chosen in Nokcandu are swapped
// with macOS's own keyboard remapping (hidutil's UserKeyMapping, the same mechanism as System Settings →
// Keyboard → Modifier Keys), so a remapped key is a real key to macOS too: fn as Control holds like Control and
// doesn't trigger fn's own shortcuts. Switching to another app, or the game quitting, puts the keyboard back.
// No system-wide remapper and no Input Monitoring are needed.
//
// Settings: "key-remap" next to this library (the Windows environment's state folder): one "source target" pair
// of HID usages (hex, as hidutil takes them) per line. Read each time the game comes to the front.
// While active, ~/Library/Application Support/Nokcandu/key-remap-active holds this process id and the keyboard
// mapping that was there before (restored afterwards), so Nokcandu can put it back if this process dies.
#import <AppKit/AppKit.h>
#include <spawn.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <crt_externs.h>
#include "program-input-settings.h"
extern char **environ;

static char key_remap_path[PATH_MAX], key_marker_path[PATH_MAX];
static _Atomic bool key_applied;
static char key_previous[4096] = "[]";
static dispatch_queue_t key_q;

static bool key_run(const char *json, char *out, size_t outsize) {
    int fds[2] = {-1, -1};
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    if (out && pipe(fds) == 0) { posix_spawn_file_actions_adddup2(&fa, fds[1], 1); posix_spawn_file_actions_addclose(&fa, fds[0]); }
    else posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", O_WRONLY, 0);
    char *set[] = {"/usr/bin/hidutil", "property", "--set", (char *)json, NULL};
    char *get[] = {"/usr/bin/hidutil", "property", "--get", "UserKeyMapping", NULL};
    pid_t pid; int status = -1;
    bool ok = posix_spawn(&pid, "/usr/bin/hidutil", &fa, NULL, json ? set : get, environ) == 0;
    posix_spawn_file_actions_destroy(&fa);
    if (fds[1] >= 0) close(fds[1]);
    if (ok && out) {
        size_t n = 0; ssize_t r;
        while (n + 1 < outsize && (r = read(fds[0], out + n, outsize - 1 - n)) > 0) n += (size_t)r;
        out[n] = 0;
    }
    if (fds[0] >= 0) close(fds[0]);
    if (ok) waitpid(pid, &status, 0);
    return ok && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

// hidutil --get prints one block per keyboard; the first block's pairs are taken as "the mapping before".
static void key_save_previous(void) {
    char out[16384];
    if (!key_run(NULL, out, sizeof out)) return;
    char *p = out, buf[4096] = "[";
    size_t len = 1; bool first = true;
    unsigned long long dst = 0, src = 0; bool haveDst = false, haveSrc = false;
    char *end = strchr(out, ')');      // end of the first keyboard's list
    while ((p = strstr(p, "HIDKeyboardModifierMapping")) && (!end || p < end)) {
        if (!strncmp(p, "HIDKeyboardModifierMappingDst", 29)) { dst = strtoull(strchr(p, '=') + 1, NULL, 10); haveDst = true; }
        else if (!strncmp(p, "HIDKeyboardModifierMappingSrc", 29)) { src = strtoull(strchr(p, '=') + 1, NULL, 10); haveSrc = true; }
        p += 26;
        if (haveDst && haveSrc) {
            len += snprintf(buf + len, sizeof buf - len, "%s{\"HIDKeyboardModifierMappingSrc\":%llu,\"HIDKeyboardModifierMappingDst\":%llu}", first ? "" : ",", src, dst);
            first = false; haveDst = haveSrc = false;
            if (len >= sizeof buf - 100) break;
        }
    }
    snprintf(buf + len, sizeof buf - len, "]");
    strlcpy(key_previous, buf, sizeof key_previous);
}

static void key_apply(void) {
    FILE *f = key_remap_path[0] ? fopen(key_remap_path, "r") : NULL;
    if (!f) return;
    char json[8192] = "{\"UserKeyMapping\":[", line[128];
    size_t len = strlen(json); int pairs = 0;
    while (fgets(line, sizeof line, f) && len < sizeof json - 128) {
        unsigned long long src, dst;
        if (sscanf(line, "%llx %llx", &src, &dst) != 2) continue;
        len += snprintf(json + len, sizeof json - len, "%s{\"HIDKeyboardModifierMappingSrc\":%llu,\"HIDKeyboardModifierMappingDst\":%llu}", pairs ? "," : "", src, dst);
        pairs++;
    }
    fclose(f);
    if (!pairs) return;
    snprintf(json + len, sizeof json - len, "]}");
    if (!atomic_load(&key_applied)) key_save_previous();
    if (key_run(json, NULL, 0)) {
        atomic_store(&key_applied, true);
        FILE *m = fopen(key_marker_path, "w");
        if (m) { fprintf(m, "%d\n%s\n", getpid(), key_previous); fclose(m); }
    }
}

static void key_restore(void) {
    if (!atomic_exchange(&key_applied, false)) return;
    char json[4200];
    snprintf(json, sizeof json, "{\"UserKeyMapping\":%s}", key_previous);
    key_run(json, NULL, 0);
    unlink(key_marker_path);
}

static void install_key_remap(const char *folder) {
    const char *home = getenv("HOME");
    if (!folder || !home) return;
    snprintf(key_remap_path, sizeof key_remap_path, "%s/key-remap", folder);
    // A game inside a shared launcher (Steam, Battle.net…) may have keys of its own: key-remap.tsv routes its
    // programs to them.
    int argc = *_NSGetArgc(); char **argv = *_NSGetArgv();
    if (argc > 1) {
        char routes[PATH_MAX], own[PATH_MAX];
        snprintf(routes, sizeof routes, "%s/key-remap.tsv", folder);
        if (nokcandu_program_input(routes, argv[1], own, sizeof own)) strlcpy(key_remap_path, own, sizeof key_remap_path);
    }
    snprintf(key_marker_path, sizeof key_marker_path, "%s/Library/Application Support/Nokcandu/key-remap-active", home);
    key_q = dispatch_queue_create("nokcandu.keyremap", DISPATCH_QUEUE_SERIAL);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *n) { dispatch_async(key_q, ^{ key_apply(); }); }];
    [nc addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *n) { dispatch_async(key_q, ^{ key_restore(); }); }];
    [nc addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                usingBlock:^(__unused NSNotification *n) { dispatch_sync(key_q, ^{ key_restore(); }); }];
    // Wine owns this process's signal handlers; a process that is killed is put right by Nokcandu (key-remap-active).
    atexit(key_restore);
    if (NSApp.isActive) dispatch_async(key_q, ^{ key_apply(); });
}
