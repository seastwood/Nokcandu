/* Keep a native app alive as the responsible process for its launcher script.
 * LaunchServices otherwise attributes a script-only app to /bin/bash, which
 * cannot request macOS removable-volume permission on the game's behalf. */
#include <CoreFoundation/CoreFoundation.h>
#include <spawn.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <limits.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <time.h>
extern char **environ;
static volatile sig_atomic_t child;
static char status_path[PATH_MAX];
static double started;
static void status_record(const char *phase, int code) {
    if (!*status_path) return;
    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof(temporary), "%s.%d", status_path, getpid()) >= (int)sizeof(temporary)) return;
    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    if (dprintf(fd, "{\"startedAt\":%.6f,\"phase\":\"%s\",\"exitCode\":%d,\"pid\":%d}\n", started, phase, code, getpid()) > 0) {
        close(fd); rename(temporary, status_path);
    } else { close(fd); unlink(temporary); }
}
static void forward(int sig) { if (child > 0) kill((pid_t)child, sig); }
int main(int argc, char **argv) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFTypeRef value = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("NokcanduLauncherScript"));
    char name[256], folder[PATH_MAX], path[PATH_MAX];
    if (!value || CFGetTypeID(value) != CFStringGetTypeID() ||
        !CFStringGetCString(value, name, sizeof(name), kCFStringEncodingUTF8) ||
        !*name || strchr(name, '/') || !strcmp(name, ".") || !strcmp(name, "..")) return 126;
    CFURLRef executable = CFBundleCopyExecutableURL(bundle);
    if (!executable || !CFURLGetFileSystemRepresentation(executable, true, (UInt8 *)folder, sizeof(folder))) return 126;
    CFRelease(executable);
    char *slash = strrchr(folder, '/'); if (!slash) return 126; *slash = 0;
    if (snprintf(path, sizeof(path), "%s/%s", folder, name) >= (int)sizeof(path) || access(path, R_OK)) return 126;
    char logs[PATH_MAX];
    if (snprintf(logs, sizeof(logs), "%s/../SharedSupport/Logs", folder) < (int)sizeof(logs)) {
        mkdir(logs, 0700);
        if (snprintf(status_path, sizeof(status_path), "%s/launcher-status.json", logs) >= (int)sizeof(status_path)) *status_path = 0;
    }
    struct timespec now; clock_gettime(CLOCK_REALTIME, &now); started = now.tv_sec + now.tv_nsec / 1000000000.0;
    status_record("starting", 0);
    char **args = calloc((size_t)argc + 2, sizeof(*args)); if (!args) { status_record("exited", 126); return 126; }
    args[0] = "/bin/bash"; args[1] = path;
    for (int i = 1; i < argc; i++) args[i + 1] = argv[i];
    signal(SIGTERM, forward); signal(SIGINT, forward); signal(SIGHUP, forward);
    pid_t pid; int error = posix_spawn(&pid, "/bin/bash", NULL, NULL, args, environ); free(args);
    if (error) { status_record("exited", 126); fprintf(stderr, "Nokcandu launcher: %s\n", strerror(error)); return 126; }
    child = pid;
    int status;
    while (waitpid(pid, &status, 0) < 0) if (errno != EINTR) return 126;
    child = 0;
    int result = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
    status_record("exited", result);
    return result;
}
