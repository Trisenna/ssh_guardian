/*
 * ssh_guardian.c
 *
 * 用户态守护进程：当本机 SSH 服务不可用时，自动清杀当前用户的训练进程以恢复系统。
 *
 * 检测方式：定期 fork+exec ssh localhost /bin/true，走完整 SSH 登录流程。
 * 清杀策略：两级——先杀最大的 1 个候选进程，等待后若仍失败则全杀。
 * 日志策略：平时写磁盘日志；紧急时只写 /dev/shm（tmpfs）；恢复后把内存环形
 *           缓冲区补写到磁盘。
 *
 * 编译：gcc -static -O2 -o ssh_guardian ssh_guardian.c
 * 用法：./ssh_guardian [选项]  （详见 --help）
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <time.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <stdarg.h>

/* ========================================================================
 * 常量与默认值
 * ======================================================================== */

#define MAX_ALLOW       32
#define MAX_EXCLUDE     32
#define MAX_PROCS       1024
#define RING_BUF_LINES  200
#define RING_LINE_LEN   512
#define PATH_BUF        512

/* 默认参数 */
#define DEF_INTERVAL        5
#define DEF_TIMEOUT         8
#define DEF_FAIL_THRESHOLD  3
#define DEF_COOLDOWN        300
#define DEF_KILL_COUNT      1
#define DEF_MIN_RSS_MB      512
#define DEF_RECOVERY_WAIT   15
#define DEF_ALLOW           "python,python3"
#define DEF_EXCLUDE         "bash,zsh,sh,fish,tmux,screen,sshd,ssh,login,jupyter-lab,jupyter-notebook"
#define DEF_SHM_LOG         "/dev/shm/ssh_guardian.log"

/* ========================================================================
 * 全局配置
 * ======================================================================== */

static struct {
    int   interval;          /* 检测间隔（秒） */
    int   timeout;           /* 单次 SSH 超时（秒） */
    int   fail_threshold;    /* 连续失败多少次触发 */
    int   cooldown;          /* 清杀后冷却（秒） */
    int   kill_count;        /* 第一级杀几个 */
    int   min_rss_mb;        /* 候选进程最低 RSS (MB) */
    int   recovery_wait;     /* 第一级杀完后等多久再检测（秒） */
    int   dry_run;           /* 1 = 只记录不真杀 */

    char  allow[MAX_ALLOW][64];
    int   allow_cnt;
    char  exclude[MAX_EXCLUDE][64];
    int   exclude_cnt;

    char  log_file[PATH_BUF];    /* 磁盘日志路径 */
    char  shm_log[PATH_BUF];     /* /dev/shm 日志路径 */
} cfg;

static volatile sig_atomic_t g_running = 1;

/* ========================================================================
 * 环形缓冲区——用于紧急时在内存中暂存日志
 * ======================================================================== */

static char   ring_buf[RING_BUF_LINES][RING_LINE_LEN];
static int    ring_head  = 0;   /* 下一条写入位置 */
static int    ring_count = 0;   /* 当前有效条数 */

static void ring_push(const char *line)
{
    strncpy(ring_buf[ring_head], line, RING_LINE_LEN - 1);
    ring_buf[ring_head][RING_LINE_LEN - 1] = '\0';
    ring_head = (ring_head + 1) % RING_BUF_LINES;
    if (ring_count < RING_BUF_LINES)
        ring_count++;
}

/* 把环形缓冲区内容追加写到文件，然后清空 */
static void ring_flush_to_file(const char *path)
{
    if (ring_count == 0) return;

    FILE *fp = fopen(path, "a");
    if (!fp) return;

    int start;
    if (ring_count < RING_BUF_LINES)
        start = 0;
    else
        start = ring_head;  /* head 就是最老的那条 */

    for (int i = 0; i < ring_count; i++) {
        int idx = (start + i) % RING_BUF_LINES;
        fprintf(fp, "%s\n", ring_buf[idx]);
    }

    fclose(fp);
    ring_count = 0;
    ring_head  = 0;
}

/* ========================================================================
 * 日志系统
 *
 * 模式：
 *   NORMAL  —— 同时写磁盘日志 + /dev/shm + stderr + 环形缓冲区
 *   EMERGENCY —— 只写 /dev/shm + stderr + 环形缓冲区，不碰磁盘
 * ======================================================================== */

typedef enum { LOG_NORMAL, LOG_EMERGENCY } log_mode_t;
static log_mode_t g_log_mode = LOG_NORMAL;

static void get_timestr(char *buf, int len)
{
    time_t now = time(NULL);
    struct tm tm;
    localtime_r(&now, &tm);
    strftime(buf, len, "%Y-%m-%d %H:%M:%S", &tm);
}

static void log_msg(const char *fmt, ...)
    __attribute__((format(printf, 1, 2)));

static void log_msg(const char *fmt, ...)
{
    char timebuf[32];
    get_timestr(timebuf, sizeof(timebuf));

    char body[RING_LINE_LEN - 40];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    char line[RING_LINE_LEN];
    snprintf(line, sizeof(line), "[%s] %s", timebuf, body);

    /* 始终写入环形缓冲区 */
    ring_push(line);

    /* 始终写 stderr */
    fprintf(stderr, "%s\n", line);

    /* 始终写 /dev/shm */
    if (cfg.shm_log[0]) {
        FILE *fp = fopen(cfg.shm_log, "a");
        if (fp) {
            fprintf(fp, "%s\n", line);
            fclose(fp);
        }
    }

    /* 仅 NORMAL 模式写磁盘日志 */
    if (g_log_mode == LOG_NORMAL && cfg.log_file[0]) {
        FILE *fp = fopen(cfg.log_file, "a");
        if (fp) {
            fprintf(fp, "%s\n", line);
            fclose(fp);
        }
    }
}

/* 恢复后把紧急期间的日志补写到磁盘 */
static void flush_emergency_log(void)
{
    if (cfg.log_file[0]) {
        ring_flush_to_file(cfg.log_file);
        log_msg("RECOVERY: emergency ring buffer flushed to %s", cfg.log_file);
    }
}

/* ========================================================================
 * 辅助：解析逗号分隔列表
 * ======================================================================== */

static int parse_csv(const char *input, char arr[][64], int max_items)
{
    int cnt = 0;
    const char *p = input;
    while (*p && cnt < max_items) {
        const char *comma = strchr(p, ',');
        int len;
        if (comma)
            len = (int)(comma - p);
        else
            len = (int)strlen(p);
        if (len > 0 && len < 64) {
            memcpy(arr[cnt], p, len);
            arr[cnt][len] = '\0';
            cnt++;
        }
        if (comma)
            p = comma + 1;
        else
            break;
    }
    return cnt;
}

/* ========================================================================
 * 辅助：读 /proc 文件的一行或多行
 * ======================================================================== */

/* 读取整个小文件到 buf，返回读取字节数，-1 失败 */
static int read_proc_file(const char *path, char *buf, int buflen)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    int n = (int)read(fd, buf, buflen - 1);
    close(fd);
    if (n < 0) return -1;
    buf[n] = '\0';
    return n;
}

/* 从 /proc/meminfo 风格文件中找 "key:" 对应的 kB 值 */
static long parse_meminfo_kb(const char *buf, const char *key)
{
    const char *p = strstr(buf, key);
    if (!p) return -1;
    p += strlen(key);
    while (*p == ' ' || *p == ':') p++;
    return strtol(p, NULL, 10);
}

/* ========================================================================
 * SSH 检测
 * ======================================================================== */

static int check_ssh(void)
{
    pid_t pid = fork();
    if (pid < 0) {
        log_msg("SSH_CHECK: fork() failed: %s", strerror(errno));
        return -1;
    }

    if (pid == 0) {
        /* 子进程：exec ssh */
        /* 关闭 stdin */
        close(STDIN_FILENO);
        open("/dev/null", O_RDONLY);

        /* 重定向 stdout/stderr 到 /dev/null */
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDOUT_FILENO);
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }

        execlp("ssh", "ssh",
               "-n",
               "-o", "BatchMode=yes",
               "-o", "PasswordAuthentication=no",
               "-o", "KbdInteractiveAuthentication=no",
               "-o", "PreferredAuthentications=publickey",
               "-o", "StrictHostKeyChecking=no",
               "-o", "ConnectTimeout=5",
               "-o", "ServerAliveInterval=2",
               "-o", "ServerAliveCountMax=1",
               "localhost",
               "/bin/true",
               (char *)NULL);
        _exit(127);
    }

    /* 父进程：带超时等待子进程 */
    int elapsed = 0;
    int status;
    while (elapsed < cfg.timeout) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w > 0) {
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0)
                return 0;  /* 成功 */
            else
                return -1; /* SSH 失败 */
        }
        if (w < 0) return -1;
        sleep(1);
        elapsed++;
    }

    /* 超时：杀掉子进程 */
    kill(pid, SIGKILL);
    waitpid(pid, &status, 0);
    return -1;
}

/* ========================================================================
 * 读取系统指标（仅用于日志，不参与触发判断）
 * ======================================================================== */

typedef struct {
    long mem_avail_mb;
    long swap_free_mb;
    double io_some_avg10;
    double io_full_avg10;
} sys_metrics_t;

static void read_sys_metrics(sys_metrics_t *m)
{
    char buf[4096];

    m->mem_avail_mb  = -1;
    m->swap_free_mb  = -1;
    m->io_some_avg10 = -1.0;
    m->io_full_avg10 = -1.0;

    /* /proc/meminfo */
    if (read_proc_file("/proc/meminfo", buf, sizeof(buf)) > 0) {
        long avail = parse_meminfo_kb(buf, "MemAvailable");
        long sfree = parse_meminfo_kb(buf, "SwapFree");
        if (avail >= 0) m->mem_avail_mb = avail / 1024;
        if (sfree >= 0) m->swap_free_mb = sfree / 1024;
    }

    /* /proc/pressure/io  (PSI, 需要内核 4.20+) */
    if (read_proc_file("/proc/pressure/io", buf, sizeof(buf)) > 0) {
        /*
         * 格式示例：
         * some avg10=0.00 avg60=0.00 avg300=0.00 total=0
         * full avg10=0.00 avg60=0.00 avg300=0.00 total=0
         */
        const char *some = strstr(buf, "some ");
        if (some) {
            const char *a = strstr(some, "avg10=");
            if (a) m->io_some_avg10 = strtod(a + 6, NULL);
        }
        const char *full = strstr(buf, "full ");
        if (full) {
            const char *a = strstr(full, "avg10=");
            if (a) m->io_full_avg10 = strtod(a + 6, NULL);
        }
    }
}

/* ========================================================================
 * 进程扫描与清杀
 * ======================================================================== */

typedef struct {
    pid_t pid;
    char  comm[64];
    long  rss_mb;
    char  state;
} proc_info_t;

static int is_in_list(const char *name, char list[][64], int cnt)
{
    for (int i = 0; i < cnt; i++) {
        if (strcmp(name, list[i]) == 0) return 1;
    }
    return 0;
}

/* 扫描 /proc，收集当前用户的候选进程 */
static int scan_candidates(proc_info_t *procs, int max_procs)
{
    uid_t myuid = getuid();
    DIR *dp = opendir("/proc");
    if (!dp) return 0;

    int count = 0;
    struct dirent *ent;

    while ((ent = readdir(dp)) != NULL && count < max_procs) {
        /* 只看数字目录 */
        if (ent->d_name[0] < '0' || ent->d_name[0] > '9')
            continue;

        pid_t pid = (pid_t)atoi(ent->d_name);
        if (pid <= 0) continue;

        /* 不杀自己 */
        if (pid == getpid()) continue;

        char path[PATH_BUF];
        char buf[4096];

        /* 读 /proc/<pid>/status */
        snprintf(path, sizeof(path), "/proc/%d/status", pid);
        if (read_proc_file(path, buf, sizeof(buf)) <= 0) continue;

        /* 检查 UID */
        const char *uid_line = strstr(buf, "\nUid:");
        if (!uid_line) continue;
        uid_line += 5; /* 跳过 "\nUid:" */
        uid_t real_uid = (uid_t)strtoul(uid_line, NULL, 10);
        if (real_uid != myuid) continue;

        /* 读进程名 */
        char comm[64] = {0};
        const char *name_line = strstr(buf, "Name:");
        if (name_line) {
            name_line += 5;
            while (*name_line == ' ' || *name_line == '\t') name_line++;
            int i = 0;
            while (name_line[i] && name_line[i] != '\n' && i < 63) {
                comm[i] = name_line[i];
                i++;
            }
            comm[i] = '\0';
        }
        if (comm[0] == '\0') continue;

        /* 检查 allowlist / denylist */
        if (cfg.allow_cnt > 0 && !is_in_list(comm, cfg.allow, cfg.allow_cnt))
            continue;
        if (is_in_list(comm, cfg.exclude, cfg.exclude_cnt))
            continue;

        /* 读 VmRSS */
        long rss_kb = -1;
        const char *rss_line = strstr(buf, "\nVmRSS:");
        if (rss_line) {
            rss_line += 7;
            rss_kb = strtol(rss_line, NULL, 10);
        }
        if (rss_kb < 0) continue;
        long rss_mb = rss_kb / 1024;
        if (rss_mb < cfg.min_rss_mb) continue;

        /* 读状态 */
        char state = '?';
        const char *state_line = strstr(buf, "\nState:");
        if (state_line) {
            state_line += 7;
            while (*state_line == ' ' || *state_line == '\t') state_line++;
            state = *state_line;
        }

        procs[count].pid    = pid;
        procs[count].rss_mb = rss_mb;
        procs[count].state  = state;
        strncpy(procs[count].comm, comm, sizeof(procs[count].comm) - 1);
        count++;
    }

    closedir(dp);
    return count;
}

/* 排序比较：D 状态优先，然后按 RSS 降序 */
static int cmp_procs(const void *a, const void *b)
{
    const proc_info_t *pa = (const proc_info_t *)a;
    const proc_info_t *pb = (const proc_info_t *)b;

    /* D 状态排前面 */
    int da = (pa->state == 'D') ? 1 : 0;
    int db = (pb->state == 'D') ? 1 : 0;
    if (da != db) return db - da;

    /* RSS 大的排前面 */
    if (pb->rss_mb != pa->rss_mb)
        return (pb->rss_mb > pa->rss_mb) ? 1 : -1;
    return 0;
}

/* 执行清杀，返回杀了几个 */
static int kill_procs(proc_info_t *procs, int count, int max_kill)
{
    int killed = 0;
    for (int i = 0; i < count && killed < max_kill; i++) {
        if (cfg.dry_run) {
            log_msg("DRY_RUN: would kill pid=%d comm=%s rss=%ldMB state=%c",
                    procs[i].pid, procs[i].comm, procs[i].rss_mb, procs[i].state);
        } else {
            int ret = kill(procs[i].pid, SIGKILL);
            log_msg("KILL: pid=%d comm=%s rss=%ldMB state=%c result=%s",
                    procs[i].pid, procs[i].comm, procs[i].rss_mb, procs[i].state,
                    ret == 0 ? "OK" : strerror(errno));
        }
        killed++;
    }
    return killed;
}

/* ========================================================================
 * 信号处理
 * ======================================================================== */

static void sig_handler(int sig)
{
    (void)sig;
    g_running = 0;
}

/* ========================================================================
 * 命令行解析
 * ======================================================================== */

static void print_usage(const char *prog)
{
    fprintf(stderr,
        "Usage: %s [options]\n"
        "\n"
        "Options:\n"
        "  --interval N        检测间隔秒数 (default: %d)\n"
        "  --timeout N         SSH 超时秒数 (default: %d)\n"
        "  --fail-threshold N  连续失败触发阈值 (default: %d)\n"
        "  --cooldown N        清杀后冷却秒数 (default: %d)\n"
        "  --kill-count N      第一级杀几个 (default: %d)\n"
        "  --min-rss-mb N      候选进程最低 RSS MB (default: %d)\n"
        "  --recovery-wait N   第一级后等待秒数 (default: %d)\n"
        "  --allow LIST        允许杀的进程名, 逗号分隔 (default: %s)\n"
        "  --exclude LIST      绝不杀的进程名, 逗号分隔 (default: %s)\n"
        "  --log-file PATH     磁盘日志路径 (default: ~/ssh_guardian.log)\n"
        "  --shm-log PATH      /dev/shm 日志路径 (default: %s)\n"
        "  --dry-run           只检测记录, 不真杀\n"
        "  --help              显示此帮助\n",
        prog,
        DEF_INTERVAL, DEF_TIMEOUT, DEF_FAIL_THRESHOLD, DEF_COOLDOWN,
        DEF_KILL_COUNT, DEF_MIN_RSS_MB, DEF_RECOVERY_WAIT,
        DEF_ALLOW, DEF_EXCLUDE, DEF_SHM_LOG);
}

static void parse_args(int argc, char **argv)
{
    /* 设置默认值 */
    cfg.interval       = DEF_INTERVAL;
    cfg.timeout        = DEF_TIMEOUT;
    cfg.fail_threshold = DEF_FAIL_THRESHOLD;
    cfg.cooldown       = DEF_COOLDOWN;
    cfg.kill_count     = DEF_KILL_COUNT;
    cfg.min_rss_mb     = DEF_MIN_RSS_MB;
    cfg.recovery_wait  = DEF_RECOVERY_WAIT;
    cfg.dry_run        = 0;

    cfg.allow_cnt   = parse_csv(DEF_ALLOW,   cfg.allow,   MAX_ALLOW);
    cfg.exclude_cnt = parse_csv(DEF_EXCLUDE, cfg.exclude, MAX_EXCLUDE);

    /* 默认磁盘日志: ~/ssh_guardian.log */
    const char *home = getenv("HOME");
    if (home)
        snprintf(cfg.log_file, sizeof(cfg.log_file), "%s/ssh_guardian.log", home);
    else
        snprintf(cfg.log_file, sizeof(cfg.log_file), "/tmp/ssh_guardian.log");

    strncpy(cfg.shm_log, DEF_SHM_LOG, sizeof(cfg.shm_log) - 1);

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            exit(0);
        }
        else if (strcmp(argv[i], "--dry-run") == 0) {
            cfg.dry_run = 1;
        }
        else if (strcmp(argv[i], "--interval") == 0 && i + 1 < argc)
            cfg.interval = atoi(argv[++i]);
        else if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc)
            cfg.timeout = atoi(argv[++i]);
        else if (strcmp(argv[i], "--fail-threshold") == 0 && i + 1 < argc)
            cfg.fail_threshold = atoi(argv[++i]);
        else if (strcmp(argv[i], "--cooldown") == 0 && i + 1 < argc)
            cfg.cooldown = atoi(argv[++i]);
        else if (strcmp(argv[i], "--kill-count") == 0 && i + 1 < argc)
            cfg.kill_count = atoi(argv[++i]);
        else if (strcmp(argv[i], "--min-rss-mb") == 0 && i + 1 < argc)
            cfg.min_rss_mb = atoi(argv[++i]);
        else if (strcmp(argv[i], "--recovery-wait") == 0 && i + 1 < argc)
            cfg.recovery_wait = atoi(argv[++i]);
        else if (strcmp(argv[i], "--allow") == 0 && i + 1 < argc)
            cfg.allow_cnt = parse_csv(argv[++i], cfg.allow, MAX_ALLOW);
        else if (strcmp(argv[i], "--exclude") == 0 && i + 1 < argc)
            cfg.exclude_cnt = parse_csv(argv[++i], cfg.exclude, MAX_EXCLUDE);
        else if (strcmp(argv[i], "--log-file") == 0 && i + 1 < argc)
            strncpy(cfg.log_file, argv[++i], sizeof(cfg.log_file) - 1);
        else if (strcmp(argv[i], "--shm-log") == 0 && i + 1 < argc)
            strncpy(cfg.shm_log, argv[++i], sizeof(cfg.shm_log) - 1);
        else {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            print_usage(argv[0]);
            exit(1);
        }
    }
}

/* ========================================================================
 * 主循环
 * ======================================================================== */

int main(int argc, char **argv)
{
    parse_args(argc, argv);

    /* 注册信号 */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sig_handler;
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    log_msg("========================================");
    log_msg("ssh_guardian started (pid=%d uid=%d)", getpid(), getuid());
    log_msg("  interval=%d timeout=%d fail_threshold=%d cooldown=%d",
            cfg.interval, cfg.timeout, cfg.fail_threshold, cfg.cooldown);
    log_msg("  kill_count=%d min_rss_mb=%d recovery_wait=%d dry_run=%d",
            cfg.kill_count, cfg.min_rss_mb, cfg.recovery_wait, cfg.dry_run);

    char allow_str[1024] = {0};
    for (int i = 0; i < cfg.allow_cnt; i++) {
        if (i > 0) strcat(allow_str, ",");
        strcat(allow_str, cfg.allow[i]);
    }
    char exclude_str[1024] = {0};
    for (int i = 0; i < cfg.exclude_cnt; i++) {
        if (i > 0) strcat(exclude_str, ",");
        strcat(exclude_str, cfg.exclude[i]);
    }
    log_msg("  allow=[%s]", allow_str);
    log_msg("  exclude=[%s]", exclude_str);
    log_msg("  log_file=%s", cfg.log_file);
    log_msg("  shm_log=%s", cfg.shm_log);
    log_msg("========================================");

    int  fail_count  = 0;
    int  in_cooldown = 0;
    time_t cooldown_until = 0;
    int  was_emergency = 0;  /* 标记是否曾进入紧急模式 */

    while (g_running) {
        /* 冷却期检查 */
        if (in_cooldown) {
            time_t now = time(NULL);
            if (now >= cooldown_until) {
                log_msg("COOLDOWN: ended");
                in_cooldown = 0;
            } else {
                log_msg("COOLDOWN: %ld seconds remaining",
                        (long)(cooldown_until - now));
                sleep(cfg.interval);
                continue;
            }
        }

        /* SSH 检测 */
        int ssh_ok = check_ssh();

        if (ssh_ok == 0) {
            /* SSH 正常 */
            if (fail_count > 0) {
                log_msg("SSH_CHECK: OK (recovered after %d failures)", fail_count);
            }
            fail_count = 0;

            /* 如果之前处于紧急模式，现在恢复了，补写日志 */
            if (was_emergency) {
                g_log_mode = LOG_NORMAL;
                flush_emergency_log();
                was_emergency = 0;
                log_msg("RECOVERY: system recovered, disk logging resumed");
            }

            sleep(cfg.interval);
            continue;
        }

        /* SSH 失败 */
        fail_count++;

        /* 读取系统指标（仅用于日志） */
        sys_metrics_t met;
        read_sys_metrics(&met);

        log_msg("SSH_CHECK: FAILED (%d/%d) | MemAvail=%ldMB SwapFree=%ldMB "
                "IoSome10=%.1f IoFull10=%.1f",
                fail_count, cfg.fail_threshold,
                met.mem_avail_mb, met.swap_free_mb,
                met.io_some_avg10, met.io_full_avg10);

        if (fail_count < cfg.fail_threshold) {
            sleep(cfg.interval);
            continue;
        }

        /* ============================================================
         * 触发清杀
         * ============================================================ */

        log_msg("TRIGGER: %d consecutive SSH failures, entering emergency mode",
                fail_count);

        /* 切换到紧急日志模式 */
        g_log_mode = LOG_EMERGENCY;
        was_emergency = 1;

        /* 扫描候选进程 */
        proc_info_t procs[MAX_PROCS];
        int nprocs = scan_candidates(procs, MAX_PROCS);

        if (nprocs == 0) {
            log_msg("SCAN: no candidate processes found, nothing to kill");
            in_cooldown = 1;
            cooldown_until = time(NULL) + cfg.cooldown;
            fail_count = 0;
            sleep(cfg.interval);
            continue;
        }

        qsort(procs, nprocs, sizeof(proc_info_t), cmp_procs);

        log_msg("SCAN: found %d candidate(s):", nprocs);
        for (int i = 0; i < nprocs; i++) {
            log_msg("  [%d] pid=%d comm=%s rss=%ldMB state=%c",
                    i, procs[i].pid, procs[i].comm, procs[i].rss_mb,
                    procs[i].state);
        }

        /* --- 第一级：温和清杀 --- */
        log_msg("STAGE1: killing top %d candidate(s)", cfg.kill_count);
        int killed1 = kill_procs(procs, nprocs, cfg.kill_count);
        log_msg("STAGE1: killed %d process(es), waiting %d seconds...",
                killed1, cfg.recovery_wait);

        sleep(cfg.recovery_wait);

        /* 再检测一次 */
        ssh_ok = check_ssh();
        if (ssh_ok == 0) {
            log_msg("STAGE1: SSH recovered after killing %d process(es)", killed1);
            in_cooldown = 1;
            cooldown_until = time(NULL) + cfg.cooldown;
            fail_count = 0;
            sleep(cfg.interval);
            continue;
        }

        /* --- 第二级：彻底清杀 --- */
        log_msg("STAGE2: SSH still down, killing ALL candidates");

        /* 重新扫描（第一级杀的可能已经退出，可能有新的） */
        nprocs = scan_candidates(procs, MAX_PROCS);
        if (nprocs > 0) {
            qsort(procs, nprocs, sizeof(proc_info_t), cmp_procs);
            int killed2 = kill_procs(procs, nprocs, nprocs); /* 全杀 */
            log_msg("STAGE2: killed %d process(es)", killed2);
        } else {
            log_msg("STAGE2: no remaining candidates");
        }

        /* 等一下看是否恢复 */
        sleep(cfg.recovery_wait);
        ssh_ok = check_ssh();
        if (ssh_ok == 0) {
            log_msg("STAGE2: SSH recovered after full cleanup");
        } else {
            log_msg("STAGE2: SSH still down after full cleanup. "
                    "Cause is likely beyond user processes.");
        }

        /* 无论是否恢复，都进入冷却 */
        in_cooldown = 1;
        cooldown_until = time(NULL) + cfg.cooldown;
        fail_count = 0;

        sleep(cfg.interval);
    }

    log_msg("ssh_guardian stopping (signal received)");

    /* 退出前把环形缓冲区里的内容写到磁盘 */
    if (cfg.log_file[0]) {
        g_log_mode = LOG_NORMAL;
        ring_flush_to_file(cfg.log_file);
    }

    return 0;
}
