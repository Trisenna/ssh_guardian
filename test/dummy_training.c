/*
 * dummy_training.c
 *
 * 编译后重命名为 python3，模拟训练进程。
 * 分配并 touch 一块内存让 VmRSS 可见，然后 sleep 直到被杀。
 *
 * 用法: ./python3 <alloc_mb>
 *   alloc_mb: 分配多少 MB 内存 (会实际写入使其进入 RSS)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

int main(int argc, char **argv)
{
    int mb = 2;  /* 默认 2MB，测试够用 */
    if (argc > 1) mb = atoi(argv[1]);
    if (mb < 1) mb = 1;

    size_t sz = (size_t)mb * 1024 * 1024;
    char *buf = malloc(sz);
    if (!buf) {
        fprintf(stderr, "dummy_training: malloc %d MB failed\n", mb);
        return 1;
    }

    /* 逐页写入，确保物理页被分配进 RSS */
    for (size_t i = 0; i < sz; i += 4096) {
        buf[i] = (char)(i & 0xFF);
    }

    fprintf(stdout, "dummy_training: pid=%d allocated %d MB, sleeping...\n",
            getpid(), mb);
    fflush(stdout);

    /* 写一个 pid 文件方便测试脚本追踪 */
    const char *pidfile = getenv("DUMMY_PIDFILE");
    if (pidfile) {
        FILE *fp = fopen(pidfile, "w");
        if (fp) {
            fprintf(fp, "%d\n", getpid());
            fclose(fp);
        }
    }

    while (1) {
        sleep(3600);
    }

    free(buf);
    return 0;
}
