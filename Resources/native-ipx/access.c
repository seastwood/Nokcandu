/* Nokcandu's optional native-IPX session access helper.
 * Unprivileged clients register their own launcher's PID/start identity. A
 * separately authorized, hash-checked root copy owns only BPF permission leases.
 * No permanent daemon, group membership, network driver, or fixed match timer. */
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/acl.h>
#include <sys/sysctl.h>
#include <sys/user.h>
#include <libproc.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <unistd.h>

#define MAGIC 0x4e495058u
#define MAX_BPF 128
struct identity { uint32_t pid; uint64_t sec, usec; };
struct header { uint32_t magic, version, uid, ready, count; struct identity process; };
struct device { uint32_t index; uint64_t rdev; };
static volatile sig_atomic_t stopping;
static void stop_handler(int value) { (void)value; stopping = 1; }
static uid_t manager_owner(void) {
#ifdef NOK_IPX_TEST
    return getuid();
#else
    return 0;
#endif
}
static int process_identity(pid_t pid, uid_t uid, struct identity *out) {
    if (pid < 1) return 0;
    struct proc_bsdinfo info;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)) {
        if (info.pbi_uid != uid || info.pbi_status == SZOMB) return 0;
        out->pid = (uint32_t)pid; out->sec = info.pbi_start_tvsec; out->usec = info.pbi_start_tvusec;
        return 1;
    }
    /* A normal account cannot query some root processes through libproc. The
     * public process table supplies the same owner/start identity without task access. */
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc public_info; size_t size = sizeof(public_info);
    if (sysctl(mib, 4, &public_info, &size, NULL, 0) || size != sizeof(public_info) ||
        public_info.kp_eproc.e_ucred.cr_uid != uid || public_info.kp_proc.p_stat == SZOMB) return 0;
    out->pid = (uint32_t)pid; out->sec = public_info.kp_proc.p_starttime.tv_sec;
    out->usec = public_info.kp_proc.p_starttime.tv_usec;
    return 1;
}
static int same_process(struct identity saved, uid_t uid) {
    struct identity now;
    return process_identity((pid_t)saved.pid, uid, &now) && now.sec == saved.sec && now.usec == saved.usec;
}
static int path_for(uid_t uid, int state, char *out, size_t size) {
#ifdef NOK_IPX_TEST
    (void)uid;
    const char *home = getenv("NOK_IPX_TEST_HOME");
    if (!home || !*home) return -1;
    int n = snprintf(out, size, "%s/%s", home, state ? "manager.state" : "sessions");
#else
    struct passwd *account = getpwuid(uid);
    if (!account || !account->pw_dir || uid == 0) return -1;
    int n = state ? snprintf(out, size, "/private/var/run/nokcandu-native-ipx-%u.state", uid) :
        snprintf(out, size, "%s/Library/Application Support/Nokcandu/NativeIPXSessions", account->pw_dir);
#endif
    return n >= 0 && (size_t)n < size ? 0 : -1;
}
static int regular_owned(int fd, uid_t uid, mode_t mode) {
    struct stat st;
    return fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == uid &&
        (st.st_mode & 07777) == mode && st.st_nlink == 1;
}
static int session_directory(uid_t uid, int create) {
    char path[PATH_MAX]; struct stat st;
    if (path_for(uid, 0, path, sizeof(path))) return -1;
    if (create && mkdir(path, 0700) != 0 && errno != EEXIST) return -1;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fstat(fd, &st) || st.st_uid != uid || !S_ISDIR(st.st_mode) || (st.st_mode & 07777) != 0700) { close(fd); return -1; }
    return fd;
}
static int session_lock(int directory, uid_t uid, int create, int wait) {
    int fd = openat(directory, ".lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (create ? O_CREAT : 0), 0600);
    if (fd < 0) return -1;
    if (!regular_owned(fd, uid, 0600) || flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB))) { close(fd); return -1; }
    return fd;
}
static int valid_session(int directory, const char *name, uid_t uid) {
    if (strncmp(name, "session.", 8) || strchr(name, '/')) return 0;
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return 0;
    char bytes[128]; ssize_t n = regular_owned(fd, uid, 0600) ? read(fd, bytes, sizeof(bytes) - 1) : -1;
    close(fd); if (n <= 0) return 0; bytes[n] = 0;
    unsigned pid; unsigned long long sec, usec; char trailing;
    if (sscanf(bytes, "NOKIPX2 %u %llu %llu %c", &pid, &sec, &usec, &trailing) != 3 || pid > INT_MAX) return 0;
    return same_process((struct identity){ pid, sec, usec }, uid);
}
static int active_sessions(int directory, uid_t uid, int prune) {
    int copy = dup(directory); if (copy < 0) return -1;
    DIR *dir = fdopendir(copy); if (!dir) { close(copy); return -1; }
    rewinddir(dir); int count = 0, inspected = 0; struct dirent *item;
    while ((item = readdir(dir))) {
        if (strncmp(item->d_name, "session.", 8)) continue;
        if (++inspected > 4096) { count = -1; break; }
        if (valid_session(directory, item->d_name, uid)) count++;
        else if (prune) {
            int fd = openat(directory, item->d_name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
            if (fd >= 0) { if (regular_owned(fd, uid, 0600)) unlinkat(directory, item->d_name, 0); close(fd); }
        }
    }
    closedir(dir); return count;
}
static int register_session(pid_t pid) {
    uid_t uid = getuid(); struct identity identity;
    if (!uid || pid <= 1 || geteuid() != uid || !process_identity(pid, uid, &identity)) return 1;
    int directory = session_directory(uid, 1); if (directory < 0) { perror("Native IPX session folder"); return 1; }
    int lock = session_lock(directory, uid, 1, 1); if (lock < 0) { close(directory); return 1; }
    active_sessions(directory, uid, 1);
    char path[PATH_MAX], template[PATH_MAX]; path_for(uid, 0, path, sizeof(path));
    snprintf(template, sizeof(template), "%s/session.%u.XXXXXXXX", path, (unsigned)pid);
    int fd = mkstemp(template); int result = 1;
    if (fd >= 0) {
        if (fchmod(fd, 0600) == 0 && dprintf(fd, "NOKIPX2 %u %llu %llu\n", identity.pid,
            (unsigned long long)identity.sec, (unsigned long long)identity.usec) > 0 && fsync(fd) == 0) {
            puts(strrchr(template, '/') + 1); result = 0;
        } else unlink(template);
        close(fd);
    }
    close(lock); close(directory); return result;
}
static int unregister_session(const char *token) {
    if (strncmp(token, "session.", 8) || strchr(token, '/') || strstr(token, "..")) return 1;
    int directory = session_directory(getuid(), 0); if (directory < 0) return 1;
    int lock = session_lock(directory, getuid(), 0, 1); if (lock < 0) { close(directory); return 1; }
    int fd = openat(directory, token, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), result = 1;
    if (fd >= 0) { if (regular_owned(fd, getuid(), 0600)) result = unlinkat(directory, token, 0) ? 1 : 0; close(fd); }
    close(lock); close(directory); return result;
}
static int read_header(int fd, uid_t uid, struct header *header) {
    return pread(fd, header, sizeof(*header), 0) == sizeof(*header) && header->magic == MAGIC &&
        header->version == 2 && header->uid == uid && header->count <= MAX_BPF;
}
static int check_manager(void) {
    uid_t uid = getuid(); char path[PATH_MAX]; struct header header;
    if (!uid || path_for(uid, 1, path, sizeof(path))) return 1;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC); if (fd < 0) return 1;
    int valid = regular_owned(fd, manager_owner(), 0644) && read_header(fd, uid, &header) && header.ready &&
        same_process(header.process, manager_owner());
    if (valid && flock(fd, LOCK_SH | LOCK_NB) == 0) { flock(fd, LOCK_UN); valid = 0; }
    close(fd); return valid ? 0 : 1;
}
#ifndef NOK_IPX_TEST
static int has_acl(const char *path) {
    acl_t acl = acl_get_file(path, ACL_TYPE_EXTENDED); if (!acl) return errno != ENOENT && errno != ENOTSUP;
    acl_entry_t entry; int present = acl_get_entry(acl, ACL_FIRST_ENTRY, &entry) == 0; acl_free(acl); return present;
}
static int device_matches(const char *path, uid_t uid, uint64_t rdev) {
    struct stat st;
    return lstat(path, &st) == 0 && S_ISCHR(st.st_mode) && st.st_uid == uid && st.st_gid == 0 &&
        (st.st_mode & 07777) == 0600 && (uint64_t)st.st_rdev == rdev && !has_acl(path);
}
#endif
static void restore_devices(struct device *devices, unsigned count, uid_t uid) {
#ifndef NOK_IPX_TEST
    for (unsigned i = 0; i < count; i++) {
        char path[64]; snprintf(path, sizeof(path), "/dev/bpf%u", devices[i].index);
        if (device_matches(path, uid, devices[i].rdev)) lchown(path, 0, 0);
    }
#else
    (void)devices; (void)count; (void)uid;
#endif
}
/* Open only unbound, untouched BPF endpoints, forcing a small pool of spare
 * kernel endpoints for concurrent games. No interface or capture is configured. */
static void prepare_spares(void) {
#ifndef NOK_IPX_TEST
    int held[16], count = 0;
    for (unsigned i = 0; i < MAX_BPF && count < 16; i++) {
        char path[64]; struct stat st; snprintf(path, sizeof(path), "/dev/bpf%u", i);
        if (!lstat(path, &st) && device_matches(path, 0, (uint64_t)st.st_rdev)) {
            int fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
            if (fd >= 0) held[count++] = fd;
        }
    }
    for (int i = 0; i < count; i++) close(held[i]);
#endif
}
static int grant_devices(int fd, struct header *header, struct device *devices) {
#ifndef NOK_IPX_TEST
    for (unsigned index = 0; index < MAX_BPF; index++) {
        char path[64]; struct stat st; snprintf(path, sizeof(path), "/dev/bpf%u", index);
        if (lstat(path, &st)) continue;
        int recorded = 0; for (unsigned j = 0; j < header->count; j++) if (devices[j].index == index) recorded = 1;
        if (recorded || !device_matches(path, 0, (uint64_t)st.st_rdev)) continue;
        if (header->count >= MAX_BPF) return -1;
        struct device record; memset(&record, 0, sizeof(record)); record.index = index; record.rdev = (uint64_t)st.st_rdev;
        if (pwrite(fd, &record, sizeof(record), sizeof(*header) + header->count * sizeof(record)) != sizeof(record) || fsync(fd)) return -1;
        devices[header->count++] = record;
        if (pwrite(fd, &header->count, sizeof(header->count), offsetof(struct header, count)) != sizeof(header->count) || fsync(fd)) return -1;
        if (!device_matches(path, 0, record.rdev) || lchown(path, header->uid, 0)) return -1;
    }
#else
    (void)fd; (void)header; (void)devices;
#endif
    return 0;
}
static void clean_stage(const char *stage) {
    char path[PATH_MAX]; snprintf(path, sizeof(path), "%s/native-ipx-access", stage); unlink(path); rmdir(stage);
}
static void send_status(int fd, const char *message) { dprintf(fd, "%s\n", message); close(fd); }
static int enable(uid_t uid, const char *stage) {
#ifndef NOK_IPX_TEST
    if (geteuid() != 0 || setgroups(0, NULL) || setgid(0) || setuid(0)) { fputs("Native IPX requires administrator authorization.\n", stderr); return 1; }
#endif
    struct stat st; char state_path[PATH_MAX], real_stage[PATH_MAX];
    if (!uid || !realpath(stage, real_stage) || lstat(real_stage, &st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != manager_owner() || (st.st_mode & 07777) != 0700) { fputs("Native IPX protected staging is invalid.\n", stderr); return 1; }
#ifndef NOK_IPX_TEST
    if (strncmp(real_stage, "/private/tmp/nokcandu-ipx.", 26)) { fputs("Native IPX staging location is invalid.\n", stderr); return 1; }
#endif
    int directory = session_directory(uid, 0); if (directory < 0) { perror("Native IPX session folder"); return 1; }
    int session_guard = session_lock(directory, uid, 0, 1);
    if (session_guard < 0 || active_sessions(directory, uid, 0) <= 0) {
        fputs("The native IPX game session is no longer active.\n", stderr); if (session_guard >= 0) close(session_guard); close(directory); return 1;
    }
    if (path_for(uid, 1, state_path, sizeof(state_path))) return 1;
    int created = 0;
    int state = open(state_path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0644);
    if (state >= 0) { created = 1; if (fchmod(state, 0644)) { close(state); unlink(state_path); state = -1; } }
    else if (errno == EEXIST) state = open(state_path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    (void)created;
    if (state < 0 || !regular_owned(state, manager_owner(), 0644)) { perror("Native IPX manager state"); if (state >= 0) close(state); close(session_guard); close(directory); return 1; }
    if (flock(state, LOCK_EX | LOCK_NB)) {
        struct header existing; int valid = read_header(state, uid, &existing) && existing.ready && same_process(existing.process, manager_owner());
        close(state); close(session_guard); close(directory);
        if (valid) { clean_stage(real_stage); puts("Native IPX session access is ready."); return 0; }
        fputs("Another native IPX permission request is still starting.\n", stderr); return 1;
    }
    struct header old; struct device devices[MAX_BPF] = {0};
    if (read_header(state, uid, &old) && pread(state, devices, old.count * sizeof(*devices), sizeof(old)) == old.count * sizeof(*devices)) restore_devices(devices, old.count, uid);
    ftruncate(state, 0); close(session_guard);
    int ack[2]; if (pipe(ack)) { close(state); close(directory); return 1; }
    pid_t child = fork();
    if (child < 0) { close(ack[0]); close(ack[1]); close(state); close(directory); return 1; }
    if (child > 0) {
        close(ack[1]); close(state); close(directory);
        char message[256]; ssize_t n = read(ack[0], message, sizeof(message) - 1); close(ack[0]);
        if (n > 0) { message[n] = 0; fputs(message, message[0] == '+' ? stdout : stderr); return message[0] == '+' ? 0 : 1; }
        fputs("Native IPX manager exited before confirming startup.\n", stderr); return 1;
    }
    close(ack[0]);
    if (setsid() < 0) { send_status(ack[1], "- Native IPX could not detach its session manager."); _exit(1); }
    int null = open("/dev/null", O_RDWR); if (null >= 0) { dup2(null, 0); dup2(null, 1); dup2(null, 2); if (null > 2) close(null); }
    struct header header; memset(&header, 0, sizeof(header)); header.magic = MAGIC; header.version = 2; header.uid = uid;
    process_identity(getpid(), manager_owner(), &header.process);
    memset(devices, 0, sizeof(devices));
    prepare_spares();
    signal(SIGTERM, stop_handler); signal(SIGINT, stop_handler); signal(SIGHUP, SIG_IGN);
    if (pwrite(state, &header, sizeof(header), 0) != sizeof(header) || fsync(state) || grant_devices(state, &header, devices)) {
        restore_devices(devices, header.count, uid); unlink(state_path); send_status(ack[1], "- Native IPX could not prepare capture permissions."); close(state); close(directory); clean_stage(real_stage); _exit(1);
    }
    header.ready = 1; pwrite(state, &header.ready, sizeof(header.ready), offsetof(struct header, ready)); fsync(state);
    send_status(ack[1], "+ Native IPX session access is ready.");
    int empty = 0;
    while (!stopping) {
        int lock = session_lock(directory, uid, 0, 0);
        if (lock >= 0) {
            int active = active_sessions(directory, uid, 0);
            if (active == 0) empty++; else empty = 0;
            if (empty >= 2 || active < 0) {
                restore_devices(devices, header.count, uid); unlink(state_path); close(state); close(lock); close(directory); clean_stage(real_stage); _exit(0);
            }
            close(lock);
        }
        if (grant_devices(state, &header, devices)) break;
        usleep(500000);
    }
    restore_devices(devices, header.count, uid); unlink(state_path); close(state); close(directory); clean_stage(real_stage); _exit(0);
}
int main(int argc, char **argv) {
#ifdef NOK_IPX_TEST
    if (argc == 4 && !strcmp(argv[1], "--test-identity")) {
        struct identity identity; return process_identity((pid_t)atoi(argv[2]), (uid_t)atoi(argv[3]), &identity) ? 0 : 1;
    }
#endif
    if (argc == 3 && !strcmp(argv[1], "--register")) {
        char *end; long pid = strtol(argv[2], &end, 10); return !*end && pid > 1 && pid <= INT_MAX ? register_session((pid_t)pid) : 1;
    }
    if (argc == 3 && !strcmp(argv[1], "--unregister")) return unregister_session(argv[2]);
    if (argc == 2 && !strcmp(argv[1], "--check")) return check_manager();
    if (argc == 4 && !strcmp(argv[1], "--enable")) {
        char *end; unsigned long uid = strtoul(argv[2], &end, 10); if (!*end && uid > 0 && uid <= UINT32_MAX) return enable((uid_t)uid, argv[3]);
    }
    fputs("Usage: native-ipx-access --register PID | --unregister TOKEN | --check | --enable UID PROTECTED-STAGE\n", stderr); return 1;
}
