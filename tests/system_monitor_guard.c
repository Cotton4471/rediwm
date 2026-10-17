/* Noninstalled LD_PRELOAD fixture. Supervise real signal syscalls so a UI
 * selection regression cannot signal anything except this test's children.
 * The production monitor contains no test hooks and still uses real pidfds. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

extern char *program_invocation_short_name;
static const char *targets;
static int listener;

static int allowed_target(int pid) {
    FILE *file = fopen(targets, "re");
    if (!file) return 0;
    int owner = 0, candidate = 0;
    unsigned long long start = 0, wanted = 0;
    if (fscanf(file, "%d", &owner) != 1) { fclose(file); return 0; }
    while (fscanf(file, "%d %llu", &candidate, &start) == 2) {
        if (candidate == pid) { wanted = start; break; }
    }
    fclose(file);
    if (!wanted || owner <= 0 || pid <= 1) return 0;

    char path[80], stat[4096];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    ssize_t n = read(fd, stat, sizeof(stat) - 1);
    close(fd);
    if (n <= 0) return 0;
    stat[n] = 0;
    char *fields = strrchr(stat, ')');
    if (!fields) return 0;
    fields++;
    char *save = NULL;
    int parent = 0;
    start = 0;
    for (int i = 0; i <= 19; i++) {
        char *field = strtok_r(i ? NULL : fields, " \n", &save);
        if (!field) return 0;
        if (i == 1) parent = (int)strtol(field, NULL, 10);
        if (i == 19) start = strtoull(field, NULL, 10);
    }
    /* Parent and start time also reject any reused fixture PID. */
    return parent == owner && start == wanted;
}

static int pidfd_target(int tid, int fd) {
    char path[96], line[256];
    snprintf(path, sizeof(path), "/proc/%d/fdinfo/%d", tid, fd);
    FILE *file = fopen(path, "re");
    if (!file) return -1;
    int pid = -1;
    while (fgets(line, sizeof(line), file)) {
        if (sscanf(line, "Pid: %d", &pid) == 1) break;
    }
    fclose(file);
    return pid;
}

static void *supervise(void *unused) {
    (void)unused;
    for (;;) {
        struct seccomp_notif request = {0};
        struct seccomp_notif_resp response = {0};
        if (ioctl(listener, SECCOMP_IOCTL_NOTIF_RECV, &request) < 0) {
            if (errno == EINTR || errno == ENOENT) continue;
            _exit(125); /* Fail closed if supervision stops. */
        }
        int permit = 0;
        int nr = request.data.nr;
        if (nr == __NR_pidfd_send_signal) {
            int sig = (int)request.data.args[1];
            int pid = pidfd_target((int)request.pid, (int)request.data.args[0]);
            permit = (sig == SIGTERM || sig == SIGKILL) && allowed_target(pid);
        } else if (nr == __NR_kill) {
            int pid = (int)request.data.args[0];
            permit = pid == getpid() || allowed_target(pid);
        } else if (nr == __NR_tgkill) {
            /* Permit a runtime to signal its own threads, never another app. */
            permit = (int)request.data.args[0] == getpid();
        }
        response.id = request.id;
        if (permit) response.flags = SECCOMP_USER_NOTIF_FLAG_CONTINUE;
        else response.error = -EPERM;
        if (ioctl(listener, SECCOMP_IOCTL_NOTIF_SEND, &response) < 0 && errno != ENOENT)
            _exit(125);
    }
    return NULL;
}

__attribute__((constructor)) static void install_guard(void) {
    if (strcmp(program_invocation_short_name, "rediwm-monitor") != 0) return;
    targets = getenv("REDIWM_TEST_MONITOR_TARGETS");
    if (!targets) _exit(125);
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_pidfd_send_signal, 4, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_kill, 3, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_tgkill, 2, 0),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_tkill, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_USER_NOTIF),
    };
    struct sock_fprog program = { .len = sizeof(filter) / sizeof(filter[0]), .filter = filter };
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) _exit(125);
    listener = (int)syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_NEW_LISTENER, &program);
    if (listener < 0) _exit(125);
    if (fcntl(listener, F_SETFD, FD_CLOEXEC) != 0) _exit(125);
    pthread_t thread;
    if (pthread_create(&thread, NULL, supervise, NULL) != 0) _exit(125);
    pthread_detach(thread);
}
