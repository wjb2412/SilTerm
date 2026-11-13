#ifndef SILTERM_SHIM_H
#define SILTERM_SHIM_H

#include <sys/types.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 在伪终端中启动一个 shell 进程。
/// @param shell  可执行文件路径，例如 /bin/zsh
/// @param argv   以 NULL 结尾的参数数组（argv[0] 通常为 "-zsh" 表示登录 shell）
/// @param cwd    初始工作目录，可为 NULL
/// @param rows   终端行数
/// @param cols   终端列数
/// @param pid_out 输出子进程 pid
/// @return PTY master fd，失败返回 -1
int silterm_spawn_pty(const char *shell, char *const argv[], const char *cwd,
                      int rows, int cols, pid_t *pid_out);

/// 调整 PTY 窗口大小。
int silterm_resize_pty(int fd, int rows, int cols);

/// 读取指定进程当前工作目录（libproc 实现，仅 macOS）。
/// @return 0 成功，-1 失败
int silterm_process_cwd(pid_t pid, char *buf, size_t buflen);

#ifdef __cplusplus
}
#endif

#endif /* SILTERM_SHIM_H */
