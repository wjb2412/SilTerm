#include "CShim.h"

#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/proc_info.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

int silterm_spawn_pty(const char *shell, char *const argv[], const char *cwd,
                      int rows, int cols, pid_t *pid_out) {
    if (!shell) {
        errno = EINVAL;
        return -1;
    }

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);

    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &ws);
    if (pid < 0) {
        return -1;
    }

    if (pid == 0) {
        /* 子进程：只做 async-signal-safe 的准备工作，然后 exec */
        const char *home = getenv("HOME");
        if (cwd && cwd[0]) {
            if (chdir(cwd) != 0 && home) {
                chdir(home);
            }
        }
        setenv("TERM", "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        setenv("TERM_PROGRAM", "SilTerm", 1);
        setenv("TERM_PROGRAM_VERSION", "1.0.0", 1);
        /* 保持 LANG / LC_* 继承，不覆盖用户环境 */

        execv(shell, argv);
        /* exec 失败时给用户一个提示后退出 */
        fprintf(stderr, "SilTerm: failed to exec %s: %s\r\n", shell, strerror(errno));
        _exit(127);
    }

    /* 父进程 */
    fcntl(master, F_SETFD, FD_CLOEXEC);
    if (pid_out) {
        *pid_out = pid;
    }
    return master;
}

int silterm_resize_pty(int fd, int rows, int cols) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)(rows > 0 ? rows : 24);
    ws.ws_col = (unsigned short)(cols > 0 ? cols : 80);
    return ioctl(fd, TIOCSWINSZ, &ws);
}

int silterm_process_cwd(pid_t pid, char *buf, size_t buflen) {
    if (!buf || buflen == 0) {
        return -1;
    }
    struct proc_vnodepathinfo vpi;
    memset(&vpi, 0, sizeof(vpi));
    int rc = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof(vpi));
    if (rc <= 0) {
        return -1;
    }
    strlcpy(buf, vpi.pvi_cdir.vip_path, buflen);
    return 0;
}
