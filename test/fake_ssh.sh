#!/bin/bash
# fake_ssh.sh
#
# 替代真实 ssh，通过读取控制文件决定返回成功还是失败。
# 放在 PATH 最前面，ssh_guardian 的 execlp("ssh",...) 就会执行这个。
#
# 控制文件: $FAKE_SSH_CONTROL
#   内容为 "ok"  → 返回 0 (SSH 正常)
#   内容为 "fail" → 返回 1 (SSH 失败)
#   内容为 "hang" → sleep 很久 (模拟超时)
#   文件不存在    → 返回 1 (默认失败)
#
# 同时记录每次调用到 $FAKE_SSH_LOG（可选）

CONTROL="${FAKE_SSH_CONTROL:-/tmp/fake_ssh_control}"
LOG="${FAKE_SSH_LOG:-/tmp/fake_ssh.log}"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TIMESTAMP] fake_ssh called: $*" >> "$LOG"

if [ ! -f "$CONTROL" ]; then
    echo "[$TIMESTAMP] control file missing, returning FAIL" >> "$LOG"
    exit 1
fi

MODE=$(cat "$CONTROL" 2>/dev/null)

case "$MODE" in
    ok)
        echo "[$TIMESTAMP] returning OK" >> "$LOG"
        exit 0
        ;;
    hang)
        echo "[$TIMESTAMP] hanging..." >> "$LOG"
        sleep 3600
        exit 1
        ;;
    *)
        echo "[$TIMESTAMP] returning FAIL" >> "$LOG"
        exit 1
        ;;
esac
